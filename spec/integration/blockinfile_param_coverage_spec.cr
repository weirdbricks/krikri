require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for `blockinfile:` - the destfile
# path alias, insertafter anchoring (and its mutual exclusion with
# insertbefore), validate:, the atomic write with unsafe_writes
# fallback, attributes:/attr:, the SELinux context params, and
# append_newline:/prepend_newline:.
#
# Every behavior below was checked against the locally-installed real
# ansible-core 2.19.4's own blockinfile.py
# (/usr/lib/python3/dist-packages/ansible/modules/blockinfile.py) - the
# argument_spec, the mutually_exclusive list, and main()'s
# blank-line-padding logic - mirroring the conventions
# lineinfile_spec.cr's own parameter-coverage pass established.
#
# Note: insertafter/insertbefore anchoring itself needs no dedicated
# unit test of the regexp rules here - blockinfile delegates to the
# SHARED LineEditor.insertion_index (same firstmatch-fix commit that
# gave lineinfile LAST-match anchoring, which real blockinfile also
# uses: its `for i, line in enumerate(lines)` loop keeps the LAST
# match and never breaks). The specs below pin the end-to-end
# behavior through the plugin binary anyway.

private def param_path(name : String) : String
  File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", name)
end

describe "blockinfile plugin - parameter coverage (destfile/insertafter/validate/attributes/SELinux/newline padding)" do
  describe "path aliases" do
    it "accepts destfile as a path alias (real Ansible's third alias)" do
      path = param_path("blockinfile-destfile-alias.txt")
      File.write(path, "line1\n")

      result = PluginSpecHelper.run("blockinfile", {"destfile" => path, "block" => "x"})

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should eq("line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "insertafter:" do
    it "anchors after the LAST regexp match (shared LineEditor anchoring, like real blockinfile)" do
      path = param_path("blockinfile-insertafter-last.txt")
      File.write(path, "marker one\njunk\nmarker two\njunk2\n")

      PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "insertafter" => "^marker"})

      File.read(path).should eq("marker one\njunk\nmarker two\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\njunk2\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "falls through to EOF when the insertafter regexp matches nothing" do
      path = param_path("blockinfile-insertafter-nomatch.txt")
      File.write(path, "line1\nline2\n")

      PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "insertafter" => "^nomatch"})

      File.read(path).should eq("line1\nline2\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    # Live-verified against ansible-core 2.19.4: the argument_spec
    # declares the pair mutually exclusive and fails with exactly
    # "parameters are mutually exclusive: insertbefore|insertafter".
    it "fails with real Ansible's exact message when insertafter and insertbefore are both given" do
      path = param_path("blockinfile-mutually-exclusive.txt")
      File.write(path, "line1\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"         => path,
        "block"        => "x",
        "insertafter"  => "^line1",
        "insertbefore" => "^line1",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("parameters are mutually exclusive: insertbefore|insertafter")
      File.read(path).should eq("line1\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "a directory path" do
    # Real Ansible: fail_json(rc=256, msg='Path %s is a directory !')
    # before any other logic - krikri previously crashed with a
    # File::ReadError from trying to File.read the directory.
    it "fails with real Ansible's message instead of crashing" do
      dir = param_path("blockinfile-dir")
      FileUtils.mkdir_p(dir)

      result = PluginSpecHelper.run("blockinfile", {"path" => dir, "block" => "x"})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("Path #{dir} is a directory !")
    ensure
      FileUtils.rmdir(dir) if dir && Dir.exists?(dir)
    end
  end

  describe "state=absent on a missing file" do
    # Real Ansible: with create=true a missing file exits
    # "File %s not present" (changed=false) WITHOUT creating it;
    # without create it fails rc=257 like any other missing path.
    it "is a no-op that creates nothing when create: true" do
      path = param_path("blockinfile-absent-missing-create.txt")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("blockinfile", {"path" => path, "state" => "absent", "create" => "true"})

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should eq("File #{path} not present")
      File.exists?(path).should be_false
    end
  end

  describe "validate:" do
    it "runs the validate command against the staged content (%s substituted) and writes on success" do
      path = param_path("blockinfile-validate-ok.txt")
      File.write(path, "before\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"     => path,
        "block"    => "managed",
        "validate" => "grep -q '^managed$' %s",
      })

      result["failed"].as_bool.should be_false
      result["changed"].as_bool.should be_true
      File.read(path).should contain("managed")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "fails the task and leaves the file untouched when the validator exits nonzero" do
      path = param_path("blockinfile-validate-fail.txt")
      File.write(path, "original\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"     => path,
        "block"    => "changed",
        "validate" => "/bin/false %s",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("failed to validate: rc:1")
      File.read(path).should eq("original\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "does not run the validator when nothing would change" do
      path = param_path("blockinfile-validate-nochange.txt")
      File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nsame\n# END ANSIBLE MANAGED BLOCK\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"     => path,
        "block"    => "same",
        "validate" => "/bin/false %s",
      })

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_false
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "fails with real Ansible's exact message when validate lacks %s" do
      path = param_path("blockinfile-validate-no-percent-s.txt")
      File.write(path, "before\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"     => path,
        "block"    => "after",
        "validate" => "true",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("validate must contain %s: true")
      File.read(path).should eq("before\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "atomic write / unsafe_writes:" do
    # The write path is now a same-directory temp file + rename (real
    # Ansible's atomic_move), so an existing file's mode must survive
    # the edit.
    it "preserves the file's mode through the atomic rename" do
      path = param_path("blockinfile-atomic-mode.txt")
      File.write(path, "a\n")
      File.chmod(path, 0o600)

      result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "b"})

      result["changed"].as_bool.should be_true
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      File.read(path).should contain("b")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "follows a symlink dest and edits the target, keeping the link" do
      target = param_path("blockinfile-symlink-target.txt")
      link = param_path("blockinfile-symlink-link.txt")
      File.write(target, "target content\n")
      File.delete(link) if File.symlink?(link) || File.exists?(link)
      File.symlink(target, link)

      result = PluginSpecHelper.run("blockinfile", {"path" => link, "block" => "via symlink"})

      result["failed"].as_bool.should be_falsey
      File.symlink?(link).should be_true
      File.read(target).should contain("via symlink")
    ensure
      File.delete(link) if link && (File.exists?(link) || File.symlink?(link))
      File.delete(target) if target && File.exists?(target)
    end

    it "accepts unsafe_writes and still writes when the rename succeeds" do
      path = param_path("blockinfile-unsafe-writes.txt")
      File.write(path, "a\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"          => path,
        "block"         => "b",
        "unsafe_writes" => "true",
      })

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should contain("b")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "seuser:/serole:/setype:/selevel: (SELinux context)" do
    # Same convention as copy_param_coverage_spec.cr's own SELinux
    # spec: real Ansible skips the whole chcon step when SELinux isn't
    # enabled on the target (set_context_if_different opens with `if
    # not self.selinux_enabled(): return changed`) - all four parts are
    # silently accepted and the task succeeds as a true no-op.
    it "does not fail the task when SELinux isn't enabled on the target (a true no-op, matching real Ansible)" do
      path = param_path("blockinfile-selinux-noop.txt")
      File.write(path, "before\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"    => path,
        "block"   => "after",
        "seuser"  => "system_u",
        "serole"  => "object_r",
        "setype"  => "etc_t",
        "selevel" => "s0",
      })

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should contain("after")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "attributes:/attr: (chattr flags)" do
    # Mirrors copy_param_coverage_spec.cr's own attr: spec - real
    # Ansible's set_attributes_if_different reports changed
    # unconditionally for '-'-prefixed requests
    # (ansible/ansible#33745).
    it "reports changed on every run for '-'-prefixed attributes, flag set or not" do
      path = param_path("blockinfile-attr-clear.txt")
      File.write(path, "x\n")

      result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "attributes" => "-i"})
      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_true

      warm = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "attributes" => "-i"})
      warm["failed"].as_bool.should be_falsey
      warm["changed"].as_bool.should be_true
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "append_newline:/prepend_newline:" do
    # Semantics from ansible-core 2.19.4's main(): prepend inserts a
    # blank line between the preceding content and the block (skipped
    # at BOF or when the preceding line is already blank); append
    # inserts one between the block and what follows (skipped at EOF
    # or when that line is already blank). Both idempotent.
    it "prepends a blank line before the block and appends one after it" do
      path = param_path("blockinfile-newline-both.txt")
      File.write(path, "first\nlast\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"            => path,
        "block"           => "managed",
        "prepend_newline" => "true",
        "append_newline"  => "true",
      })

      result["failed"].as_bool.should be_falsey
      File.read(path).should eq("first\nlast\n\n# BEGIN ANSIBLE MANAGED BLOCK\nmanaged\n# END ANSIBLE MANAGED BLOCK\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "is idempotent once the blank lines are in place" do
      path = param_path("blockinfile-newline-idempotent.txt")
      File.write(path, "first\n\n# BEGIN ANSIBLE MANAGED BLOCK\nmanaged\n# END ANSIBLE MANAGED BLOCK\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"            => path,
        "block"           => "managed",
        "prepend_newline" => "true",
        "append_newline"  => "true",
      })

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_false
      File.read(path).should eq("first\n\n# BEGIN ANSIBLE MANAGED BLOCK\nmanaged\n# END ANSIBLE MANAGED BLOCK\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "adds no trailing blank line when the block already ends the file (append at EOF)" do
      path = param_path("blockinfile-newline-append-eof.txt")
      File.write(path, "first\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"           => path,
        "block"          => "managed",
        "append_newline" => "true",
      })

      result["failed"].as_bool.should be_falsey
      File.read(path).should eq("first\n# BEGIN ANSIBLE MANAGED BLOCK\nmanaged\n# END ANSIBLE MANAGED BLOCK\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "pads an updated in-place block too, not just fresh inserts" do
      path = param_path("blockinfile-newline-update.txt")
      File.write(path, "first\n# BEGIN ANSIBLE MANAGED BLOCK\nold\n# END ANSIBLE MANAGED BLOCK\nlast\n")

      result = PluginSpecHelper.run("blockinfile", {
        "path"           => path,
        "block"          => "new",
        "append_newline" => "true",
      })

      result["failed"].as_bool.should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should eq("first\n# BEGIN ANSIBLE MANAGED BLOCK\nnew\n# END ANSIBLE MANAGED BLOCK\n\nlast\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end
end

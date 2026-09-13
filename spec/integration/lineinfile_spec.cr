require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "lineinfile plugin" do
  it "receives its config over stdin (regression: used to read argv and silently do nothing)" do
    path = tmp_path("lineinfile-stdin.txt")
    File.write(path, "existing line\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "new line",
      "state" => "present",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    File.read(path).should contain("new line")
  end

  it "is idempotent when the line already exists" do
    path = tmp_path("lineinfile-idempotent.txt")
    File.write(path, "hello world\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "hello world",
      "state" => "present",
    })

    result["changed"].as_bool.should be_false
  end

  it "reports changed when only mode: drifts, even if the line is already present (regression: robertdebock.grub round 143 - GRUB_TIMEOUT=5 already in /etc/default/grub, mode: \"0664\" silently never applied/checked)" do
    path = tmp_path("lineinfile-mode-only-drift.txt")
    File.write(path, "hello world\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "hello world",
      "state" => "present",
      "mode"  => "0664",
    })

    result["changed"].as_bool.should be_true
    (File.info(path).permissions.value & 0o777).should eq(0o664)

    # Second run: mode already correct, content already correct -> idempotent
    result2 = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "hello world",
      "state" => "present",
      "mode"  => "0664",
    })
    result2["changed"].as_bool.should be_false
  end

  it "removes a matching line when state=absent" do
    path = tmp_path("lineinfile-absent.txt")
    File.write(path, "keep me\nremove me\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"  => path,
      "line"  => "remove me",
      "state" => "absent",
    })

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("keep me")
    content.should_not contain("remove me")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("lineinfile-check-mode.txt")
    File.write(path, "original\n")

    result = PluginSpecHelper.run("lineinfile", {
      "path"       => path,
      "line"       => "added line",
      "state"      => "present",
      "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.read(path).should eq("original\n")
  end

  it "does not introduce a spurious blank line when appending to a file that already ends with a newline" do
    # Regression (found via the Ansible compat harness, compat/run.cr):
    # split("\n") always adds one trailing "" artifact when content ends
    # with "\n" - a previous version of the pop-that-artifact guard was
    # conditioned on the negation of exactly the case where it needed to
    # fire, so it never actually popped anything, leaving a blank line
    # before every appended line.
    path = tmp_path("lineinfile-no-spurious-blank.txt")
    File.write(path, "first line\nsecond line\n")

    PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "third line", "state" => "present"})

    File.read(path).should eq("first line\nsecond line\nthird line\n")
  end

  it "does not leave a spurious blank line behind after removing a line" do
    path = tmp_path("lineinfile-remove-no-blank.txt")
    File.write(path, "first line\nsecond line\nthird line\n")

    PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "first line", "state" => "absent"})

    File.read(path).should eq("second line\nthird line\n")
  end

  it "fails with a clear message when the file does not exist and create is not set" do
    path = tmp_path("lineinfile-missing.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("lineinfile", {
      "path" => path,
      "line" => "hello",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("does not exist")
  end
end

private def param_path(name : String) : String
  File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", name)
end

# Proactive parameter-coverage pass for `lineinfile:` - firstmatch:,
# search_string:, validate:, attributes:/attr:, seuser:/serole:/
# setype:/selevel:, unsafe_writes:. Every behavior below was
# live-verified against the locally-installed real ansible-core 2.19.4
# (ansible-playbook on PATH) - including how the params INTERACT
# (firstmatch flips both the regexp/search_string replacement target
# and the insertafter/insertbefore anchor; state=absent ignores
# firstmatch entirely and removes every matching line) - before being
# pinned here, mirroring the conventions copy_param_coverage_spec.cr
# established.
describe "lineinfile plugin - parameter coverage (firstmatch/search_string/validate/attributes/SELinux/unsafe_writes)" do
  describe "firstmatch:" do
    # Live-verified against ansible-core 2.19.4 (the confirmed krikri
    # bug this whole pass started from): without firstmatch the LAST
    # regexp match is replaced; with firstmatch: true the FIRST.
    it "replaces the first regexp match instead of the last" do
      path = param_path("lineinfile-firstmatch-regexp.txt")
      File.write(path, "foo=1\nbar=2\nfoo=3\nbaz=4\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"        => path,
        "regexp"      => "^foo=",
        "line"        => "foo=REPLACED",
        "insertafter" => "^bar=",
        "firstmatch"  => "true",
      })

      result["changed"].as_bool.should be_true
      File.read(path).should eq("foo=REPLACED\nbar=2\nfoo=3\nbaz=4\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "keeps replacing the last regexp match when firstmatch is unset" do
      path = param_path("lineinfile-lastmatch-regexp.txt")
      File.write(path, "foo=1\nbar=2\nfoo=3\nbaz=4\n")

      PluginSpecHelper.run("lineinfile", {
        "path"        => path,
        "regexp"      => "^foo=",
        "line"        => "foo=REPLACED",
        "insertafter" => "^bar=",
      })

      File.read(path).should eq("foo=1\nbar=2\nfoo=REPLACED\nbaz=4\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    # Live-verified against ansible-core 2.19.4: firstmatch also flips
    # the insertafter/insertbefore anchor from the last matching line
    # to the first.
    it "inserts after the first insertafter match when firstmatch is set" do
      path = param_path("lineinfile-firstmatch-insertafter.txt")
      File.write(path, "marker one\njunk\nmarker two\njunk2\n")

      PluginSpecHelper.run("lineinfile", {
        "path"        => path,
        "line"        => "INSERTED",
        "insertafter" => "^marker",
        "firstmatch"  => "true",
      })

      File.read(path).should eq("marker one\nINSERTED\njunk\nmarker two\njunk2\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "inserts after the last insertafter match when firstmatch is unset" do
      path = param_path("lineinfile-lastmatch-insertafter.txt")
      File.write(path, "marker one\njunk\nmarker two\njunk2\n")

      PluginSpecHelper.run("lineinfile", {
        "path"        => path,
        "line"        => "INSERTED",
        "insertafter" => "^marker",
      })

      File.read(path).should eq("marker one\njunk\nmarker two\nINSERTED\njunk2\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "search_string:" do
    it "replaces the last line CONTAINING the string (literal, not a regex) and is idempotent" do
      path = param_path("lineinfile-search-string.txt")
      File.write(path, "port = 22\ncomment\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "search_string" => "port",
        "line"          => "port = 2222",
      })

      result["changed"].as_bool.should be_true
      File.read(path).should eq("port = 2222\ncomment\n")

      result2 = PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "search_string" => "port",
        "line"          => "port = 2222",
      })
      result2["changed"].as_bool.should be_false
      File.read(path).should eq("port = 2222\ncomment\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "replaces the first containing line when combined with firstmatch" do
      path = param_path("lineinfile-search-string-firstmatch.txt")
      File.write(path, "alpha one\nbeta\nalpha two\n")

      PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "search_string" => "alpha",
        "line"          => "alpha REPLACED",
        "firstmatch"    => "true",
      })

      File.read(path).should eq("alpha REPLACED\nbeta\nalpha two\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "removes every line containing the string with state=absent (firstmatch never applies to absent)" do
      path = param_path("lineinfile-search-string-absent.txt")
      File.write(path, "keep\nalpha one\nkeep2\nalpha two\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "search_string" => "alpha",
        "state"         => "absent",
        "firstmatch"    => "true",
      })

      result["changed"].as_bool.should be_true
      File.read(path).should eq("keep\nkeep2\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "falls through to insertafter when the string matches nothing" do
      path = param_path("lineinfile-search-string-nomatch.txt")
      File.write(path, "header\nfooter\n")

      PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "search_string" => "nomatch",
        "line"          => "new line",
        "insertafter"   => "^header",
      })

      File.read(path).should eq("header\nnew line\nfooter\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    # Live-verified against ansible-core 2.19.4: real Ansible's own
    # argument_spec marks the pairs mutually exclusive and fails with
    # exactly these messages.
    it "fails with real Ansible's exact message when regexp and search_string are both given" do
      path = param_path("lineinfile-mutually-exclusive.txt")
      File.write(path, "x=1\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "regexp"        => "^x=",
        "search_string" => "x",
        "line"          => "z=9",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("parameters are mutually exclusive: regexp|search_string")
      File.read(path).should eq("x=1\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "fails when backrefs and search_string are both given" do
      path = param_path("lineinfile-backrefs-search-string.txt")
      File.write(path, "x=1\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "search_string" => "x",
        "line"          => "z=9",
        "backrefs"      => "true",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("parameters are mutually exclusive: backrefs|search_string")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "fails when backrefs is given without a regexp" do
      path = param_path("lineinfile-backrefs-no-regexp.txt")
      File.write(path, "x=1\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"     => path,
        "line"     => "z=9",
        "backrefs" => "true",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("regexp is required with backrefs=true")
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "validate:" do
    it "runs the validate command against the staged content (%s substituted) and writes on success" do
      path = param_path("lineinfile-validate-ok.txt")
      File.write(path, "before\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"     => path,
        "line"     => "after",
        "validate" => "grep -q '^after$' %s",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should eq("before\nafter\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    # Live-verified against ansible-core 2.19.4: a failing validator
    # fails the task with "failed to validate: rc:<n> error:<stderr>"
    # and the destination is left untouched.
    it "fails the task and leaves the file untouched when the validator exits nonzero" do
      path = param_path("lineinfile-validate-fail.txt")
      File.write(path, "original\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"     => path,
        "line"     => "changed",
        "validate" => "/bin/false %s",
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("failed to validate: rc:1")
      File.read(path).should eq("original\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    # Live-verified against ansible-core 2.19.4: the validator only
    # runs on the actual write path - an already-present line with a
    # /bin/false validator still reports ok/changed: false.
    it "does not run the validator when nothing would change" do
      path = param_path("lineinfile-validate-nochange.txt")
      File.write(path, "already here\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"     => path,
        "line"     => "already here",
        "validate" => "/bin/false %s",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_false
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "fails with real Ansible's exact message when validate lacks %s" do
      path = param_path("lineinfile-validate-no-percent-s.txt")
      File.write(path, "before\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"     => path,
        "line"     => "after",
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
      path = param_path("lineinfile-atomic-mode.txt")
      File.write(path, "a\n")
      File.chmod(path, 0o600)

      result = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "b"})

      result["changed"].as_bool.should be_true
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      File.read(path).should eq("a\nb\n")
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    # Real Ansible's atomic_move resolves a symlink dest (os.path.realpath)
    # before renaming - a lineinfile task pointing at a symlink edits the
    # file it points at and the symlink survives (the previous in-place
    # File.write followed it too).
    it "follows a symlink dest and edits the target, keeping the link" do
      target = param_path("lineinfile-symlink-target.txt")
      link = param_path("lineinfile-symlink-link.txt")
      File.write(target, "target content\n")
      File.delete(link) if File.symlink?(link) || File.exists?(link)
      File.symlink(target, link)

      result = PluginSpecHelper.run("lineinfile", {"path" => link, "line" => "via symlink"})

      result["failed"]?.try(&.as_bool).should be_falsey
      File.symlink?(link).should be_true
      File.read(target).should eq("target content\nvia symlink\n")
    ensure
      File.delete(link) if link && (File.exists?(link) || File.symlink?(link))
      File.delete(target) if target && File.exists?(target)
    end

    it "accepts unsafe_writes and still writes when the rename succeeds" do
      path = param_path("lineinfile-unsafe-writes.txt")
      File.write(path, "a\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"          => path,
        "line"          => "b",
        "unsafe_writes" => "true",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should eq("a\nb\n")
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
      path = param_path("lineinfile-selinux-noop.txt")
      File.write(path, "before\n")

      result = PluginSpecHelper.run("lineinfile", {
        "path"    => path,
        "line"    => "after",
        "seuser"  => "system_u",
        "serole"  => "object_r",
        "setype"  => "etc_t",
        "selevel" => "s0",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      File.read(path).should eq("before\nafter\n")
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
      path = param_path("lineinfile-attr-clear.txt")
      File.write(path, "x\n")

      result = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "x", "attributes" => "-i"})
      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true

      warm = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "x", "attributes" => "-i"})
      warm["failed"]?.try(&.as_bool).should be_falsey
      warm["changed"].as_bool.should be_true
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end
end

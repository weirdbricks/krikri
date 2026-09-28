require "file_utils"
require "../minitest_helper"

# Param-coverage pass for template:'s remaining documented parameters,
# mirroring test/integration/file_test.cr's conventions for the
# file-common args (SELinux context parts, attributes:/unsafe_writes:,
# follow:/force:) and the template-only rendering params (trim_blocks:,
# lstrip_blocks:, newline_sequence:, output_encoding:).
#
# Everything asserted here was live-verified against the locally
# installed real ansible-core 2.19.4 first (see the per-section
# comments for what was verified); the six delimiter-string params
# (block_start_string/block_end_string/variable_start_string/
# variable_end_string/comment_start_string/comment_end_string) are
# covered in their own section below (implemented in the vendored
# Crinja fork, crystal-play-0.9.31).
#
# Rendering params (trim_blocks:/lstrip_blocks:/newline_sequence:) live
# in the controller-side action plugin (src/krikri/
# template_action_plugin.cr), so those specs run the compiled binary
# against a real playbook - a direct plugin invocation never renders.
# The file-common args live in plugins/template.cr itself, so those
# use PluginSpecHelper.run like file_spec.cr does.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The classic suite pre-created a shared spec/tmp/template in before_suite
# (rm_rf + mkdir); the minitest suite gives every test its own tmp_path
# subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

# Runs the compiled binary against a real playbook and returns the raw
# output (for asserting task failures/message text).
private def run_playbook(playbook : String) : String
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  output.to_s
end

# A playbook rendering src: to dest: with extra task args appended.
private def render_playbook(src : String, dest : String, extra_args : String = "") : String
  File.tempname("template-param-spec", ".yml").tap do |playbook|
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      #{extra_args.empty? ? "" : "              " + extra_args}
      YAML
  end
end

# Renders *body* as a `.j2` at *name*, runs it through the compiled
# template path, and returns the rendered file contents. Used by the
# Python-%-formatting examples at the bottom of this file.
private def render_pct(name : String, body : String) : String
  src = tmp_path(name + ".j2")
  dest = tmp_path(name + ".out")
  File.write(src, body)
  playbook = render_playbook(src, dest)
  run_playbook(playbook)
  File.read(dest)
ensure
  File.delete(src) if src && File.exists?(src)
  File.delete(dest) if dest && File.exists?(dest)
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "template plugin param coverage" do
  describe "trim_blocks: (default True - Ansible's template module overrides Jinja2's own False)" do
    # Real behavior live-verified against ansible-core 2.19.4: the
    # newline after a block tag is removed by default ("A\n{% if %}\nB"
    # renders "A\nB\nC\n", no blank lines), and trim_blocks=false keeps
    # them ("A\n\nB\n\nC\n").
    it "removes the first newline after a block tag by default" do
      src = tmp_path("trim_default.j2")
      dest = tmp_path("trim_default.out")
      File.write(src, "A\n{% if true %}\nB\n{% endif %}\nC\n")

      playbook = render_playbook(src, dest)
      run_playbook(playbook)

      File.read(dest).must_equal("A\nB\nC\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "keeps the newline after a block tag with trim_blocks: false" do
      src = tmp_path("trim_off.j2")
      dest = tmp_path("trim_off.out")
      File.write(src, "A\n{% if true %}\nB\n{% endif %}\nC\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                trim_blocks: false
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("A\n\nB\n\nC\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end
  end

  describe "lstrip_blocks: (default False)" do
    # Real behavior live-verified against ansible-core 2.19.4:
    # lstrip_blocks=true strips whitespace from the start of the line
    # up to a BLOCK tag ({% %}/{# #} - not {{ }}); the default leaves
    # the indentation in the output.
    it "leaves indentation before block tags in place by default" do
      src = tmp_path("lstrip_off.j2")
      dest = tmp_path("lstrip_off.out")
      File.write(src, "A\n    {% if true %}\nB\n    {% endif %}\nC\n")

      playbook = render_playbook(src, dest)
      run_playbook(playbook)

      File.read(dest).must_equal("A\n    B\n    C\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "strips indentation before block tags with lstrip_blocks: true" do
      src = tmp_path("lstrip_on.j2")
      dest = tmp_path("lstrip_on.out")
      File.write(src, "A\n    {% if true %}\nB\n    {% endif %}\nC\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                lstrip_blocks: true
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("A\nB\nC\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "honors a #jinja2: directive override over the task param" do
      # Real Ansible's own per-template directive takes precedence over
      # the task args (the action plugin's directive_overrides.fetch) -
      # same precedence trim_blocks: already had.
      src = tmp_path("lstrip_directive.j2")
      dest = tmp_path("lstrip_directive.out")
      File.write(src, "#jinja2: lstrip_blocks: false\nA\n    {% if true %}\nB\n    {% endif %}\nC\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                lstrip_blocks: true
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("A\n    B\n    C\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end
  end

  # minitest interpolates nested describe names into generated code, so the
  # literal backslash-escape here (spec: (default "\n")) had to become text.
  describe "newline_sequence: (default LF)" do
    # Real behavior live-verified against ansible-core 2.19.4 (byte
    # level): newline_sequence="\r\n" turns the ENTIRE rendered output
    # into CRLF (every newline, not just Jinja-emitted ones), and an
    # invalid value fails the task with "newline_sequence needs to be
    # one of: \n, \r or \r\n" before any template is touched.
    it "writes \\n line endings by default" do
      src = tmp_path("nl_default.j2")
      dest = tmp_path("nl_default.out")
      File.write(src, "A\nB\n")

      playbook = render_playbook(src, dest)
      run_playbook(playbook)

      File.read(dest).must_equal("A\nB\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "converts the whole rendered output to CRLF with newline_sequence: \"\\r\\n\"" do
      src = tmp_path("nl_crlf.j2")
      dest = tmp_path("nl_crlf.out")
      File.write(src, "A\n{% if true %}\nB\n{% endif %}\nC\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                newline_sequence: "\\r\\n"
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("A\r\nB\r\nC\r\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "converts the whole rendered output to CR with newline_sequence: \"\\r\"" do
      src = tmp_path("nl_cr.j2")
      dest = tmp_path("nl_cr.out")
      File.write(src, "A\nB\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                newline_sequence: "\\r"
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("A\rB\r")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "accepts the YAML-escaped literal \"\\n\" form" do
      # Real Ansible's own wrong_sequences normalization: a literal
      # backslash-n (what CLI -e style passing or sloppy quoting often
      # hands over) means the same as a real newline.
      src = tmp_path("nl_escaped.j2")
      dest = tmp_path("nl_escaped.out")
      File.write(src, "A\nB\n")

      playbook = File.tempname("template-param-spec", ".yml")
      # Doubled backslash: a Crystal heredoc processes escapes like a
      # double-quoted string, so the YAML gets '\n' - single-quoted, i.e.
      # the LITERAL two-character backslash-n sequence. A single '\n'
      # here would put a real line break inside a single-quoted YAML
      # scalar and the generated playbook wouldn't even parse.
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                newline_sequence: '\\n'
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("A\nB\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "fails the task with real Ansible's message on an invalid value" do
      src = tmp_path("nl_bad.j2")
      dest = tmp_path("nl_bad.out")
      File.write(src, "A\nB\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                newline_sequence: "bogus"
        YAML

      output = run_playbook(playbook)

      output.must_include("newline_sequence needs to be one of")
      File.exists?(dest).must_equal(false)
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end
  end

  describe "output_encoding: (default utf-8)" do
    # Real behavior live-verified against ansible-core 2.19.4 (byte
    # level): output_encoding=latin-1 with a template containing "é"
    # writes the single byte 0xe9 (not UTF-8's 0xc3 0xa9), the default
    # writes UTF-8, and an unknown codec name fails the task with
    # "unknown encoding: ...". The source template is always READ as
    # utf-8; this only shapes the write.
    it "writes UTF-8 by default" do
      result = PluginSpecHelper.run("template", {
        "content" => "Héllo\n",
        "dest"    => tmp_path("enc_default.txt"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.open(tmp_path("enc_default.txt"), "rb", &.getb_to_end).must_equal("Héllo\n".encode("UTF-8"))
    end

    it "transcodes the written bytes with output_encoding: latin-1" do
      result = PluginSpecHelper.run("template", {
        "content"         => "Héllo\n",
        "dest"            => tmp_path("enc_latin.txt"),
        "output_encoding" => "latin-1",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.open(tmp_path("enc_latin.txt"), "rb", &.getb_to_end).must_equal("Héllo\n".encode("ISO-8859-1"))
    end

    it "re-runs as ok/changed: false against a non-UTF-8-written file (byte-level idempotency)" do
      PluginSpecHelper.run("template", {
        "content"         => "Héllo\n",
        "dest"            => tmp_path("enc_idem.txt"),
        "output_encoding" => "latin-1",
      })
      result = PluginSpecHelper.run("template", {
        "content"         => "Héllo\n",
        "dest"            => tmp_path("enc_idem.txt"),
        "output_encoding" => "latin-1",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
    end

    it "fails the task on an unknown codec name" do
      result = PluginSpecHelper.run("template", {
        "content"         => "x\n",
        "dest"            => tmp_path("enc_bad.txt"),
        "output_encoding" => "not-a-codec",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("unknown encoding: not-a-codec")
      File.exists?(tmp_path("enc_bad.txt")).must_equal(false)
    end

    it "fails the task when a character is unencodable in the target encoding" do
      # Real Ansible writes with errors='surrogate_or_strict' - "é"
      # under the ascii codec raises and fails the task (the message
      # text differs between Python's UnicodeEncodeError and iconv's,
      # so only the failure itself is pinned).
      result = PluginSpecHelper.run("template", {
        "content"         => "Héllo\n",
        "dest"            => tmp_path("enc_unencodable.txt"),
        "output_encoding" => "ascii",
      })

      result["failed"].as_bool.must_equal(true)
      File.exists?(tmp_path("enc_unencodable.txt")).must_equal(false)
    end
  end

  describe "follow: (default False)" do
    # Real behavior live-verified against ansible-core 2.19.4:
    # follow=true writes THROUGH a symlink at dest (target gets the
    # content, the link stays a link); the default replaces the symlink
    # with a regular file - even when the target already has identical
    # content (copy.py's `checksum != checksum_dest or os.path.islink`
    # write condition forces the write branch for any symlink).
    it "writes through a symlink at dest with follow: true" do
      target = tmp_path("follow_target.txt")
      link = tmp_path("follow_link.txt")
      File.write(target, "OLD\n")
      File.symlink(target, link)

      result = PluginSpecHelper.run("template", {
        "content" => "NEW\n",
        "dest"    => link,
        "follow"  => "true",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.symlink?(link).must_equal(true)
      File.read(target).must_equal("NEW\n")
    end

    it "reports ok without touching anything on a rerun with follow: true" do
      target = tmp_path("follow_idem_target.txt")
      link = tmp_path("follow_idem_link.txt")
      File.write(target, "SAME\n")
      File.symlink(target, link)

      result = PluginSpecHelper.run("template", {
        "content" => "SAME\n",
        "dest"    => link,
        "follow"  => "true",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      File.symlink?(link).must_equal(true)
    end

    it "replaces a symlink at dest with a regular file by default (even with identical content)" do
      target = tmp_path("replace_target.txt")
      link = tmp_path("replace_link.txt")
      File.write(target, "SAME\n")
      File.symlink(target, link)

      result = PluginSpecHelper.run("template", {
        "content" => "SAME\n",
        "dest"    => link,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.symlink?(link).must_equal(false)
      File.read(link).must_equal("SAME\n")
    end
  end

  describe "force: (default True)" do
    # Real behavior live-verified against ansible-core 2.19.4:
    # force=false with dest existing under different content leaves the
    # file untouched and reports plain ok/changed: false - NOT a
    # failure.
    it "overwrites an existing differing dest by default" do
      dest = tmp_path("force_default.txt")
      File.write(dest, "OLD\n")

      result = PluginSpecHelper.run("template", {
        "content" => "NEW\n",
        "dest"    => dest,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read(dest).must_equal("NEW\n")
    end

    it "leaves an existing differing dest untouched with force: false" do
      dest = tmp_path("force_off.txt")
      File.write(dest, "OLD\n")

      result = PluginSpecHelper.run("template", {
        "content" => "NEW\n",
        "dest"    => dest,
        "force"   => "false",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      File.read(dest).must_equal("OLD\n")
    end

    it "still creates a brand-new dest with force: false (round 811059/812xxx, cchurch.uwsgi)" do
      # force: false only guards an OVERWRITE of an EXISTING file - real
      # Ansible's copy.py only takes the force-skip branch inside its own
      # `if os.path.exists(dest)` check, so a dest that doesn't exist yet
      # is always created regardless of force:. This engine's own
      # `changed` starts true unconditionally and only flips to false
      # when dest exists with matching content - missing a
      # `File.exists?(dest)` guard on the force check meant `changed &&
      # !force` fired for a nonexistent dest too, wrongly reporting
      # "File already exists" (cchurch.uwsgi's own `uwsgi_conf_force:
      # false` default) for a file that had never been written.
      dest = tmp_path("force_off_new_file.txt")
      File.delete(dest) if File.exists?(dest)

      result = PluginSpecHelper.run("template", {
        "content" => "NEW\n",
        "dest"    => dest,
        "force"   => "false",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read(dest).must_equal("NEW\n")
    end
  end

  describe "unsafe_writes:" do
    # Real behavior live-verified against ansible-core 2.19.4: the copy
    # module (template: shares it) pre-checks the DESTINATION
    # DIRECTORY's writability and fails with "Destination <dir> not
    # writable"; unsafe_writes=true bypasses the check and falls back
    # to a direct, non-atomic in-place write (atomic_move's
    # _unsafe_writes), which preserves dest's inode - a hardlink to it
    # sees the new content. A read-only directory is the one case where
    # the atomic temp-file+rename genuinely cannot work (rename needs
    # directory write permission; writing the file itself doesn't).
    # These specs are meaningless under root (a root process ignores
    # the 0555 directory mode entirely), so they pass through silently
    # there.
    it "fails with real Ansible's message when the dest directory is not writable" do
      skip "needs a non-root environment" if `id -u`.strip == "0"

      dir = tmp_path("unsafe_ro_dir")
      Dir.mkdir_p(dir)
      dest = File.join(dir, "f.txt")
      File.write(dest, "BEFORE\n")
      File.chmod(dir, 0o555)

      result = PluginSpecHelper.run("template", {
        "content" => "A\nB\nC\n",
        "dest"    => dest,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Destination #{dir} not writable")
      File.read(dest).must_equal("BEFORE\n")
    ensure
      File.chmod(dir, 0o755) if dir && Dir.exists?(dir)
    end

    it "succeeds via a non-atomic in-place write when the dest directory is not writable" do
      skip "needs a non-root environment" if `id -u`.strip == "0"

      dir = tmp_path("unsafe_go_dir")
      Dir.mkdir_p(dir)
      dest = File.join(dir, "f.txt")
      File.write(dest, "BEFORE\n")
      hardlink = tmp_path("unsafe_hardlink.txt")
      File.delete(hardlink) if File.exists?(hardlink)
      File.link(dest, hardlink)
      File.chmod(dir, 0o555)

      result = PluginSpecHelper.run("template", {
        "content"       => "A\nB\nC\n",
        "dest"          => dest,
        "unsafe_writes" => "true",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read(dest).must_equal("A\nB\nC\n")
      # The in-place write preserves dest's inode - the hardlink sees
      # the new content (the atomic default path would replace the
      # inode and leave the hardlink showing the old content).
      File.read(hardlink).must_equal("A\nB\nC\n")
    ensure
      File.chmod(dir, 0o755) if dir && Dir.exists?(dir)
    end
  end

  describe "seuser:/serole:/setype:/selevel: (SELinux context params)" do
    # Identical semantics to file.cr's merged implementation (see
    # test/integration/file_test.cr's matching section, and the full
    # module_utils/basic.py grounding in file.cr's comments): real
    # Ansible accepts the params on every host but only acts when
    # SELinux is actually enabled - a graceful no-op here (this spec
    # machine is non-SELinux).
    it "accepts all four params as a graceful no-op on a non-SELinux host" do
      dest = tmp_path("se_nop.txt")

      result = PluginSpecHelper.run("template", {
        "content" => "x\n",
        "dest"    => dest,
        "seuser"  => "unconfined_u",
        "serole"  => "object_r",
        "setype"  => "httpd_sys_content_t",
        "selevel" => "s0",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result.as_h.has_key?("secontext").must_equal(false)
      File.exists?(dest).must_equal(true)
    end

    it "accepts the params on the identical-content rerun path too" do
      dest = tmp_path("se_rerun.txt")
      PluginSpecHelper.run("template", {"content" => "x\n", "dest" => dest})
      result = PluginSpecHelper.run("template", {
        "content" => "x\n",
        "dest"    => dest,
        "setype"  => "httpd_sys_content_t",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      File.read(dest).must_equal("x\n")
    end
  end

  describe "attributes: (chattr flags)" do
    # Mirrors file.cr's merged implementation (real Ansible's
    # set_attributes_if_different, applied via the real chattr binary,
    # failing the task when chattr does). Applying flags like +i needs
    # CAP_LINUX_IMMUTABLE, i.e. root - which this spec environment
    # deliberately doesn't have - so the pinned behavior is the
    # non-root failure propagation, deterministic everywhere chattr
    # exists; root environments skip.
    it "fails the task when chattr cannot apply the requested flags (non-root)" do
      skip "needs a non-root environment" if `id -u`.strip == "0"
      chattr_path = `/bin/sh -c 'command -v chattr'`.strip
      skip "no chattr binary on this host" if chattr_path.empty?

      dest = tmp_path("attr_immutable.txt")

      result = PluginSpecHelper.run("template", {
        "content"    => "x\n",
        "dest"       => dest,
        "attributes" => "+i",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("chattr failed")
    end

    it "leaves the file untouched and the task failed when chattr rejects the flags" do
      skip "needs a non-root environment" if `id -u`.strip == "0"
      chattr_path = `/bin/sh -c 'command -v chattr'`.strip
      skip "no chattr binary on this host" if chattr_path.empty?

      dest = tmp_path("attr_untouched.txt")

      result = PluginSpecHelper.run("template", {
        "content"    => "PAYLOAD\n",
        "dest"       => dest,
        "attributes" => "+i",
      })

      result["failed"].as_bool.must_equal(true)
      # Content may or may not have landed before the attribute step
      # (real Ansible writes first, applies attrs after) - but the task
      # must fail and never report success with unapplied flags.
      result["changed"].as_bool.must_equal(false)
    end
  end

  describe "delimiter-string params (block/variable/comment start+end strings)" do
    # Implemented in the vendored Crinja fork (crystal-play-0.9.31:
    # Config grew the six delimiter-string properties, the template
    # lexer matches configured strings instead of hard-coded
    # `{%`/`%}`/`{{`/`}}`/`{#`/`#}` char constants); the action plugin
    # reads the six task params into the render environment.
    #
    # Real behavior live-verified against ansible-core 2.19.4 (the
    # exact templates/assertions below):
    # - a template using `<%`/`%>` blocks, `<<`/`>>` variables and
    #   `<#`/`#>` comments renders the loop and leaves the classic
    #   `{{ }}`/`{% %}` shapes as literal text;
    # - the params are independent - overriding only the variable pair
    #   (`<<` start, `}}` end) leaves block/comment delimiters at their
    #   defaults.
    it "renders a template end-to-end with all six delimiters customized" do
      src = tmp_path("delimiters_all.j2")
      dest = tmp_path("delimiters_all.out")
      File.write(src, <<-'TEMPLATE')
        <% for item in items %>
        << item >> {{ also_literal }} {% if also_literal %}X{% endif %}
        <% endfor %>
        <# a comment #>
        TEMPLATE

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                block_start_string: '<%'
                block_end_string: '%>'
                variable_start_string: '<<'
                variable_end_string: '>>'
                comment_start_string: '<#'
                comment_end_string: '#>'
          vars:
            items: [a, b]
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal(
        "a {{ also_literal }} {% if also_literal %}X{% endif %}\n" +
        "b {{ also_literal }} {% if also_literal %}X{% endif %}\n"
      )
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end

    it "honors a partial override (only the variable delimiter pair) independently" do
      src = tmp_path("delimiters_var_only.j2")
      dest = tmp_path("delimiters_var_only.out")
      File.write(src, "GREETING = << greeting }}\nserver {{ also_literal }}\n")

      playbook = File.tempname("template-param-spec", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: render
              ansible.builtin.template:
                src: #{src}
                dest: #{dest}
                variable_start_string: '<<'
                variable_end_string: '}}'
          vars:
            greeting: hello
        YAML

      run_playbook(playbook)

      File.read(dest).must_equal("GREETING = hello\nserver {{ also_literal }}\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
      File.delete(playbook) if playbook && File.exists?(playbook)
    end
  end
end

describe "Python %-formatting in the Crinja engine (the `str % args` operator)" do
  # Real Jinja2 overloads `%` by left-operand type: a str is printf-style
  # formatting, a number is modulo. The vendored Crinja fork only did
  # numeric modulo, so `' -dns.port=%d' % (coredns_listen_port)` - verbatim
  # in rolehippie.coredns's `service.j2` (round900235) - raised "Both
  # operators need to be numeric". All expected values below were
  # live-verified against real ansible-core 2.19.4 on the same template.
  it "renders the coredns service.j2 idiom (' -dns.port=%d' % port)" do
    render_pct("pct_dnsport", %({{ " -dns.port=%d" % (53) }}\n)).must_equal(" -dns.port=53\n")
  end

  it "renders the common conversions with the same output as real Jinja2" do
    tpl = <<-TPL
      %s: {{ "%s" % "hello" }}
      %d: {{ "%d" % 42 }}
      %x: {{ "%x" % 255 }}
      %.2f: {{ "%.2f" % 3.14159 }}
      %05d: {{ "%05d" % 42 }}
      ljust: {{ "[%-10s]" % "ab" }}
      combo: {{ "%8.3f" % 3.14159 }}
      tuple: {{ "%s-%s" % ("a", "b") }}
      plus: {{ "%+d" % 7 }}
      modulo: {{ 17 % 5 }}
      TPL
    expected = <<-EXP
      %s: hello
      %d: 42
      %x: ff
      %.2f: 3.14
      %05d: 00042
      ljust: [ab        ]
      combo:    3.142
      tuple: a-b
      plus: +7
      modulo: 2
      EXP
    render_pct("pct_battery", tpl).rstrip.must_equal(expected.rstrip)
  end

  it "collapses %% and leaves numeric modulo unchanged" do
    render_pct("pct_lit", %(percent: {{ "100%% done" }}\nmod: {{ 10 % 3 }}\n))
      .must_equal("percent: 100%% done\nmod: 1\n")
  end
end

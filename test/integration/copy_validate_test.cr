require "digest/sha1"
require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against real playbooks, since this is about
# plugins/copy.cr's own filesystem staging/validate behavior, not
# reachable from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# `copy:` previously had no `validate:` handling at all (unlike
# `template:`, which supports it) - see KNOWN_MISSING.md's own
# (now-fixed) writeup. Mirrors template.cr's own staging approach:
# staged under Dir.tempdir (remote_tmp-style), validated, then moved into
# place via FileUtils.mv (falls back to copy-then-delete on a
# cross-device move).
describe "copy: with validate:" do
  it "writes content: successfully when the validate: command passes" do
    dest = File.tempname("copy-validate-content-dest")
    playbook = File.tempname("copy-validate-content", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              content: "hello world\\n"
              dest: #{dest}
              validate: "cat %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("hello world\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the task and leaves dest untouched when validate: fails, for content:" do
    dest = File.tempname("copy-validate-content-fail-dest")
    playbook = File.tempname("copy-validate-content-fail", ".yml")
    # The staged file must not outlive a failed validate; a private TMPDIR
    # lets this test look at it without matching other tests' staging.
    stage = File.join(Dir.tempdir, "copy-validate-stage-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(stage)
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              content: "hello world\\n"
              dest: #{dest}
              validate: "cp %s #{stage}/seen; false"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], env: {"TMPDIR" => stage}, output: output, error: output)

    status.success?.must_equal(false)
    # The validate command copies the staged file to "seen" first, so the
    # check below proves staging really happened under the private TMPDIR.
    File.exists?(File.join(stage, "seen")).must_equal(true)
    Dir.children(stage).none?(&.starts_with?(".krikri-playbook-copy-")).must_equal(true)
    # Ansible's copy module fails with fail_json(msg="failed to validate",
    # exit_status=rc, stdout=..., stderr=...) - the wording is
    # "failed to validate", never "Validation failed"
    # (live-verified vs 2.19.11 at -v: the fatal dump is exactly
    # {"changed": false, "checksum": ..., "exit_status": 1,
    # "msg": "failed to validate", "stderr": "", "stderr_lines": [],
    # "stdout": "", "stdout_lines": []}).
    output.to_s.must_include("\"msg\": \"failed to validate\"")
    output.to_s.must_include("\"exit_status\": 1")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
    FileUtils.rm_rf(stage) if stage && Dir.exists?(stage)
  end

  it "carries the source sha1 as checksum on the no-%s validate failure" do
    dest = File.tempname("copy-validate-nos-dest")
    playbook = File.tempname("copy-validate-nos", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              content: "hello world\\n"
              dest: #{dest}
              validate: "24"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # The gate failure is a MODULE result the copy ACTION plugin
    # post-processes: its checksum fill-in adds local_checksum (the source
    # sha1) to failed results too, so the displayed fatal carries it
    # (live-verified vs 2.19.11: {"changed": false, "checksum":
    # "<sha1>", "msg": "validate must contain %s: 24"}).
    output.to_s.must_include("validate must contain %s: 24")
    output.to_s.must_include("\"checksum\": \"#{Digest::SHA1.hexdigest("hello world\n")}\"")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "handles a %s path containing shell metacharacters (spaces)" do
    dir = File.join(Dir.tempdir, "krikri copy validate dir #{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest file")
    playbook = File.tempname("copy-validate-space", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              content: "hello world\\n"
              dest: #{dest}
              validate: "cat %s > /dev/null"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("hello world\n")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "copies src: successfully when the validate: command passes" do
    src = File.tempname("copy-validate-src")
    dest = File.tempname("copy-validate-src-dest")
    playbook = File.tempname("copy-validate-src-playbook", ".yml")
    File.write(src, "src content\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              src: #{src}
              dest: #{dest}
              validate: "cat %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("src content\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "echoes a failing validate: command's stderr raw, PID prefix included" do
    dest = File.tempname("copy-validate-stderr-dest")
    playbook = File.tempname("copy-validate-stderr", ".yml")
    validator = File.tempname("copy-validate-stderr-validator", ".sh")
    # haproxy's config check prefixes every ALERT with the PID of the
    # process that parsed the config, and Ansible hands that stderr
    # through unstripped - so krikri must too, prefix and all. That
    # shape is what scripts/output_parity.sh's [ALERT] pid mask anchors
    # on (see KNOWN_MISSING.md): if the prefix were ever trimmed or
    # rewritten here, the mask would silently stop matching and the
    # per-run PID would look like a real divergence again.
    File.write(validator, <<-SH)
      #!/bin/sh
      echo "[ALERT]    ($$) : parsing [$1] : bad directive" >&2
      exit 1
      SH
    File.chmod(validator, 0o755)
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              content: "hello world\\n"
              dest: #{dest}
              validate: "#{validator} %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include("\"msg\": \"failed to validate\"")
    # Twice: once in the merged `stderr` string and once as the only
    # `stderr_lines` entry, both keeping the validator's own prefix.
    output.to_s.scan(/\[ALERT\]    \(\d+\) : parsing \[[^\]]+\] : bad directive/).size.must_equal(2)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(validator) if validator && File.exists?(validator)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

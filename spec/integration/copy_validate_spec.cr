require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks, since this is about
# plugins/copy.cr's own filesystem staging/validate behavior, not
# reachable from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# `copy:` previously had no `validate:` handling at all (unlike
# `template:`, which supports it) - see KNOWN_MISSING.md's own
# (now-fixed) writeup. Mirrors template.cr's own staging approach:
# staged under /tmp (remote_tmp-style), validated, then moved into
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

    status.success?.should be_true
    File.read(dest).should eq("hello world\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the task and leaves dest untouched when validate: fails, for content:" do
    dest = File.tempname("copy-validate-content-fail-dest")
    playbook = File.tempname("copy-validate-content-fail", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy
            ansible.builtin.copy:
              content: "hello world\\n"
              dest: #{dest}
              validate: "false %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("Validation failed")
    File.exists?(dest).should be_false
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
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

    status.success?.should be_true
    File.read(dest).should eq("src content\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

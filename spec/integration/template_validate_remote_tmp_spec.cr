require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook, since this is about
# plugins/template.cr's own filesystem staging behavior, not reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Found via bertvv.dhcp round 312: template:'s `validate:` staging used
# to happen next to dest_dir instead of real Ansible's own remote_tmp
# (`~/.ansible/tmp/...`) location, which could make a validate: command
# confined by AppArmor/SELinux to the target program's own real config
# paths see a different outcome than real Ansible. Fixed by staging
# under /tmp (remote_tmp-style) again, using FileUtils.mv (stdlib) for
# the final move so a destination on a different filesystem than /tmp
# doesn't reintroduce the earlier cross-device File.rename bug (see
# KNOWN_MISSING.md and template.cr's own comment on temp_file).
describe "template: with validate:" do
  it "renders successfully when the validate: command passes" do
    src = File.tempname("template-validate-src", ".j2")
    dest = File.tempname("template-validate-dest")
    playbook = File.tempname("template-validate", ".yml")
    File.write(src, "hello {{ msg }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          msg: world
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              validate: "cat %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    File.read(dest).should eq("hello world\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the task, staging the rejected content under /tmp rather than next to dest, when validate: fails" do
    src = File.tempname("template-validate-src", ".j2")
    dest_dir = Dir.tempdir + "/krikri-template-validate-dest-dir-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dest_dir)
    dest = File.join(dest_dir, "out.conf")
    playbook = File.tempname("template-validate-fail", ".yml")
    File.write(src, "hello {{ msg }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          msg: world
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              validate: "false %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("Validation failed")
    output.to_s.should contain("/tmp/.krikri-playbook-template-")
    File.exists?(dest).should be_false
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end
end

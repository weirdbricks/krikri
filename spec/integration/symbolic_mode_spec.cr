require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks, since this is about
# plugins/copy.cr's and template.cr's own filesystem chmod behavior,
# not reachable from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Found via a live 100-role confirm round: two independent real roles
# (grzegorznowak.nvm_node's own `template: ... mode="u+x,g+x"`,
# srsp.oracle-java's own `copy: ... mode="a+x"`) both wrote an
# executable script that a later command: task then failed to run
# ("Permission denied"). copy.cr's/template.cr's own apply_file_
# attributes only ever recognized an all-digit OCTAL mode string -
# a genuinely SYMBOLIC mode (u+x, a+x, ...) matched neither branch and
# silently did nothing at all, unlike file.cr's own apply_mode, which
# already shells out to a real `chmod` for exactly this case.
describe "copy:/template: with a symbolic mode:" do
  it "copy: content: applies a symbolic mode via chmod, not silently dropping it" do
    dest = File.tempname("symbolic-mode-copy")
    playbook = File.tempname("symbolic-mode-copy", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: write script
            ansible.builtin.copy:
              content: "#!/bin/sh\\necho hi\\n"
              dest: #{dest}
              mode: "u+x,g+x"
          - name: run it
            ansible.builtin.command: #{dest}
            register: r
          - ansible.builtin.debug:
              msg: "OUTPUT_IS_{{ r.stdout }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("OUTPUT_IS_hi")
    (File.info(dest).permissions.value & 0o100).should_not eq(0)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "template: applies a symbolic mode via chmod, not silently dropping it" do
    src = File.tempname("symbolic-mode-template-src", ".j2")
    dest = File.tempname("symbolic-mode-template-dest")
    playbook = File.tempname("symbolic-mode-template", ".yml")
    File.write(src, "#!/bin/sh\necho hi\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: write script
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              mode: "a+x"
          - name: run it
            ansible.builtin.command: #{dest}
            register: r
          - ansible.builtin.debug:
              msg: "OUTPUT_IS_{{ r.stdout }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("OUTPUT_IS_hi")
    (File.info(dest).permissions.value & 0o100).should_not eq(0)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

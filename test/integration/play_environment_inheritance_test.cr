require "../minitest_helper"
require "file_utils"

# A play-level (or block-level) `environment:` keyword applies to every
# task underneath it, merged per variable with the innermost value
# winning (ansible-core 2.19.11, live-verified: `environment:
# {PATH: "/usr/bin:/bin"}` on the play makes a bare
# `command: {argv: [ansible-galaxy, --version]}` find the binary;
# krikri used to ignore play- and block-level environment entirely and
# fail with rc=2, "[Errno 2] No such file or directory"). The full
# binary run proves the parse -> executor -> plugin env chain end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("play-environment-inheritance", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "play environment inheritance" do
  it "applies a play-level environment PATH so command finds its binary" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        environment:
          PATH: "/usr/bin:/bin"
        tasks:
          - name: find binary via play env
            ansible.builtin.command:
              argv: [ansible-galaxy, --version]
      YAML

    status.success?.must_equal(true)
    output.must_include("changed: [localhost]")
    output.wont_include("No such file or directory")
  end

  it "lets a task-level environment override the play-level PATH" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        environment:
          PATH: "/usr/bin:/bin"
        tasks:
          - name: task PATH wins per variable
            ansible.builtin.command:
              argv: ["/bin/sh", "-c", "echo $PATH"]
            environment:
              PATH: "/opt/task-wins"
            register: override_result
          - name: show resolved PATH
            ansible.builtin.debug:
              msg: "{{ override_result.stdout }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("\"msg\": \"/opt/task-wins\"")
  end

  it "applies a block-level environment merged over the play's" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        environment:
          PLAY_ONLY: "from-play"
        tasks:
          - name: block env merges over play env
            block:
              - name: keep play var, add block var
                ansible.builtin.command:
                  argv: ["/bin/sh", "-c", "echo $PLAY_ONLY:$BLOCK_ONLY"]
                register: block_result
            environment:
              BLOCK_ONLY: "from-block"
          - name: show resolved vars
            ansible.builtin.debug:
              msg: "{{ block_result.stdout }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("\"msg\": \"from-play:from-block\"")
  end
end

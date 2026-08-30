require "file_utils"
require "../spec_helper"

# An undefined variable that flows through a FILTER is just as fatal in
# real Ansible as a bare undefined reference - `{{ nope | dict2items }}`
# fails with "dict2items requires a dictionary, got ...AnsibleUndefined",
# it does not quietly produce an empty dict. Round185, found live via
# buluma.environment's `loop: "{{ environment_list | dict2items }}"`
# (the role never defines environment_list anywhere): the task silently
# produced zero loop items and the play went green where real Ansible
# reports failed=1.
#
# All expectations below were differentialed against the local real
# ansible-core 2.19.4 with connection: local, including the tolerant
# ones: only `default`/`d`/`type_debug` survive an undefined input.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("undefined-filter-chain", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "undefined value reaching a filter is strict" do
  it "fails a loop: whose source is an undefined var piped through dict2items" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "{{ item.key }}"
            loop: "{{ environment_list | dict2items }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-SHOULD-NOT-RUN"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'environment_list' is undefined")
    output.should_not contain("SENTINEL-SHOULD-NOT-RUN")
    output.should contain("failed=1")
  end

  # The legitimate, extremely common idiom - default() consumes the
  # undefined before dict2items ever sees it, so this is zero loop items
  # and a plain skip, exactly as real Ansible reports it.
  it "still allows an explicitly defaulted source through the same chain" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "{{ item.key }}"
            loop: "{{ environment_list | default({}) | dict2items }}"
      YAML

    status.exit_code.should eq(0)
    output.should contain("skipping")
    output.should contain("skipped=1")
    output.should_not contain("failed=1")
  end

  # Round174's skip-vs-fail matrix must keep applying unchanged when the
  # undefined source reaches it through a filter chain rather than as a
  # bare reference: the task's own when: is consulted first.
  it "skips rather than fails when the task's own when: is false" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "{{ item.key }}"
            loop: "{{ environment_list | dict2items }}"
            when: false
      YAML

    status.exit_code.should eq(0)
    output.should contain("skipped=1")
    output.should_not contain("failed=1")
  end

  it "fails a module parameter templated from an undefined var through a filter" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: param
            ansible.builtin.debug:
              msg: "{{ nope | dict2items }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'nope' is undefined")
    output.should contain("failed=1")
  end

  it "fails a when: whose filter chain starts from an undefined var" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: conditional
            ansible.builtin.debug:
              msg: "hi"
            when: nope | length > 0
      YAML

    status.exit_code.should eq(2)
    output.should contain("'nope' is undefined")
    output.should contain("failed=1")
  end

  it "leaves a when: chain guarded by default() lenient" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: conditional
            ansible.builtin.debug:
              msg: "hi"
            when: nope | default([]) | length > 0
      YAML

    status.exit_code.should eq(0)
    output.should contain("skipped=1")
  end

  # The Crinja side (real `.j2` files) had the identical bug
  # independently, per this repo's own CLAUDE.md warning: its dict2items
  # returned an empty list for an undefined input, so the template task
  # rendered "[]" and reported changed instead of failing.
  it "fails a .j2 template rendering an undefined var through dict2items" do
    dir = File.tempname("undefined-filter-chain-tpl")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.j2"), "x={{ nope | dict2items }}\n")
    dest = File.join(dir, "out.txt")

    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{File.join(dir, "a.j2")}
              dest: #{dest}
      YAML

    status.exit_code.should eq(2)
    output.should contain("is undefined")
    output.should contain("failed=1")
    File.exists?(dest).should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

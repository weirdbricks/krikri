require "../minitest_helper"

# ipwrap is NOT a core Ansible filter - it comes from the ansible.utils
# collection, so the BARE `| ipwrap` spelling is unknown even with the
# collection installed (issue #134), exactly like bare `ipaddr` (#335).
# A playbook using it must fail the same way ansible-core fails any unknown
# filter: through the task-arg finalization chain with
# "No filter named 'ipwrap'" and a fatal, non-zero exit - NOT a
# successful "ok" with the raw value passed through. The FQCN spelling
# `ansible.utils.ipwrap` DOES resolve once the collection is installed
# (issue #1591).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "ipwrap is rejected as an unknown filter" do
  it "fails the task with 'No filter named ipwrap' and a non-zero exit" do
    playbook = File.tempname("ipwrap-unknown-filter", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ '::1' | ipwrap }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("No filter named 'ipwrap'")
    text.must_include("Finalization of task args for 'ansible.builtin.debug' failed")
    status.success?.must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "wraps IPv6 values through map('ansible.utils.ipwrap')" do
    playbook = File.tempname("ipwrap-fqcn-filter", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ ['127.0.0.0/8', '::ffff:127.0.0.0/104', '::1/128'] | map('ansible.utils.ipwrap') | list }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("127.0.0.0/8")
    text.must_include("[::ffff:127.0.0.0]/104")
    text.must_include("[::1]/128")
    status.success?.must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

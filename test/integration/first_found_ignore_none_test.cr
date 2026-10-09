require "../minitest_helper"

# Regression spec for `lookup('first_found', ..., errors='ignore')`
# returning None (not "") when nothing matches - and for the whole
# downstream chain that None drives. lotusnoir.apps_consul_exporter
# (round 5210000):
#
#     params: "{{ lookup('first_found', params_, errors='ignore') }}"
#     when: (params | length > 0)
#
# On real ansible-core 2.19.11 a no-match returns None and
# `None | length` fails the task with "The filter plugin
# 'ansible.builtin.length' failed: object of type 'NoneType' has no
# len()". krikri's engine-side first_found never read the errors kwarg
# (it raised, degrading downstream to an empty STRING whose length is
# 0 - the task silently skipped), and the surviving raw raise got the
# generic "Error while evaluating conditional:" prefix instead of the
# filter-plugin wrapper.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("ff-ignore", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "first_found errors=ignore returns None" do
  it "fails the when: that consumes it with Ansible's exact filter-plugin wrapper" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          params_:
            files:
              - "no-such-file-for-krikri-spec.yml"
            paths:
              - "/tmp"
          params: "{{ lookup('first_found', params_, errors='ignore') }}"
        tasks:
          - debug: msg=ran
            when: (params | length > 0)
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()")
    output.wont_include("skipping:")
  end

  it "still runs the gated task when the file exists" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          params_:
            files:
              - "inventory-explicit-localhost.ini"
            paths:
              - "#{PROJECT_ROOT}/test/fixtures"
          params: "{{ lookup('first_found', params_, errors='ignore') }}"
        tasks:
          - debug: msg=ran
            when: (params | length > 0)
      YAML

    status.exit_code.must_equal(0)
    output.must_include("ran")
  end
end

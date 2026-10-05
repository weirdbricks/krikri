require "../minitest_helper"

# Real divergence found in the round-952484 regression batch against
# stackhpc.libvirt-vm: krikri's filter-chain head eagerly strict-rendered
# EVERY field of a templated list-of-dicts, so a `when:` chain that only
# ever reads one field (`selectattr('state', ...)`) still failed on a
# SIBLING field whose own template references an intentionally-undefined
# caller variable (`name: "{{ libvirt_vm_name }}"` - the role's own
# defaults leave it to the caller). Ansible templates container
# values lazily, on actual access, so the unaccessed leaf never renders
# and the task runs.
#
# Every expectation below was verified against ansible-playbook
# 2.19.11 (localhost, no target host needed) before being written down.
#
# Scope note (deliberate, not a full laziness rewrite): the deferral only
# happens at the filter-chain head, and only for a leaf that bottoms out
# at an undefined name; every access point that DOES read the leaf still
# renders it strictly (map(attribute=...), selectattr/rejectattr value
# tests, the to_json/to_yaml/to_nice_json serializers), so all the
# pre-laziness hard failures that Ansible also produces still
# happen. Filters that consume a whole container without an explicit
# attribute extraction (sort/join/combine on deferred shapes) see the
# raw template text where Ansible would fail on access - accepted,
# documented limitation; a full lazy-container architecture was out of
# scope for one role's divergence.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("lazy-selectattr", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def playbook_for(condition : String) : String
  # The msg is built by concatenation, never written literally: real
  # ansible-core 2.19.11 (like krikri) echoes the playbook's own source
  # lines in a failing task's Origin block, so a literal "TASK-RAN" in
  # the YAML would make the wont_include("TASK-RAN") assertions below
  # match the error display of a correctly-FAILED task.
  <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        mylist:
          - state: present
            name: "{{ undefined_var }}"
      tasks:
        - name: gated
          ansible.builtin.debug:
            msg: "{{ 'TASK-' ~ 'RAN' }}"
          when: #{condition}
    YAML
end

describe "a when: filter chain over a list of dicts with an untouched undefined-template sibling field" do
  it "runs the task for a selectattr chain that only reads the other field (the round-952484 repro shape)" do
    status, output = run_playbook(playbook_for(
      "(mylist | selectattr('state', 'defined') | selectattr('state', 'equalto', 'absent') | list) != mylist"
    ))

    status.exit_code.must_equal(0)
    output.must_include("TASK-RAN")
  end

  it "runs the task for selectattr + map(attribute=...) on the accessed field only" do
    status, output = run_playbook(playbook_for(
      "(mylist | selectattr('state', 'equalto', 'present') | map(attribute='state') | list) | length > 0"
    ))

    status.exit_code.must_equal(0)
    output.must_include("TASK-RAN")
  end

  it "runs the task for an inequality comparison against the raw list" do
    status, output = run_playbook(playbook_for(
      "(mylist | selectattr('name', 'defined') | list) != mylist"
    ))

    status.exit_code.must_equal(0)
    output.must_include("TASK-RAN")
  end

  it "skips when selectattr('name', 'defined') asks about the deferred leaf itself" do
    # ansible-core 2.19.11 skips: the lazy attribute access bottoms
    # out at an undefined name, so the 'defined' test yields False for
    # the entry, the filtered list is empty, and `length > 0` is false.
    status, output = run_playbook(playbook_for(
      "(mylist | selectattr('name', 'defined') | list) | length > 0"
    ))

    status.exit_code.must_equal(0)
    output.wont_include("TASK-RAN")
    output.must_include("skipped=1")
  end

  it "still fails when map(attribute=...) actually reads the undefined leaf" do
    status, output = run_playbook(playbook_for(
      "(mylist | map(attribute='name') | list) | length > 0"
    ))

    status.exit_code.wont_equal(0)
    output.must_include("'undefined_var' is undefined")
    output.wont_include("TASK-RAN")
  end

  it "still fails a to_json task arg over a nested undefined leaf (the pre-laziness strictness)" do
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          myconfig:
            foo:
              bar: "{{ some_undefined_var }}"
        tasks:
          - name: serializer
            ansible.builtin.debug:
              msg: "{{ myconfig | to_json }}"
      YAML

    status, output = run_playbook(yaml)

    status.exit_code.wont_equal(0)
    output.must_include("'some_undefined_var' is undefined")
  end
end

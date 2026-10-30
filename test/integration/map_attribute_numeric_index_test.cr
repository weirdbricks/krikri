require "../minitest_helper"

# Xenion1987.user_management (issue #389, round29884723) merged its
# layered user lists with `groupby('name') | map(attribute='1') |
# map('last')`. Jinja2's make_attrgetter feeds each attribute segment
# through Environment.getitem, which retries an all-digit segment as an
# integer INDEX after the string lookup fails; krikri-jinja's engine-side
# get_attr only knows dict keys and method names, so every group
# resolved to an unnamed strict Undefined and the strict loop-source
# templating of `loop: "{{ user_management_all_users }}"` died with
# "'missing' is undefined" (exit 2) while ansible-playbook ran the USER
# task ok (exit 0). krikri's map wrapper resolves dotted and all-digit
# attribute paths itself.
#
# Every expectation below was verified against ansible-playbook
# (connection=local, no target host needed) before being written down.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_chain_playbook : {Process::Status, String}
  playbook = File.tempname("map-numeric-attr", ".yml")
  yaml = <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        users:
          - name: john
            state: absent
          - name: john
            state: present
          - name: jane
            state: present
        all_users: "{{ users | groupby('name') | map(attribute='1') | map('last') | list }}"
        overridden: "{{ users | groupby('name') | selectattr('1.1', 'defined') | map(attribute='0') | list }}"
      tasks:
        - name: chain to_json
          ansible.builtin.debug:
            msg: "{{ all_users | to_json }}"
        - name: overridden to_json
          ansible.builtin.debug:
            msg: "{{ overridden | to_json }}"
        - name: loop over chain
          ansible.builtin.debug:
            msg: hi
          loop: "{{ all_users }}"
          loop_control:
            label: "name: {{ item.name }}; state: {{ item.state | d('present') }}"
        - name: string index
          ansible.builtin.debug:
            msg: "{{ ['abc'] | map(attribute='1') | list | to_json }}"
    YAML
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "map(attribute=...) with an all-digit segment indexes like Jinja's getitem" do
  it "resolves the groupby pair's second element and the strict loop over it runs" do
    status, output = run_chain_playbook

    status.exit_code.must_equal(0)
    output.wont_include("'missing' is undefined")
    output.must_include("[{\\\"name\\\": \\\"jane\\\", \\\"state\\\": \\\"present\\\"}, {\\\"name\\\": \\\"john\\\", \\\"state\\\": \\\"present\\\"}]")
    output.must_include("ok: [localhost] => (item=name: jane; state: present)")
    output.must_include("ok: [localhost] => (item=name: john; state: present)")
  end

  it "selects redefined names through a dotted numeric segment chain" do
    _status, output = run_chain_playbook

    # embedded in the debug msg's JSON string, hence the doubled escaping
    output.must_include("[\\\"john\\\"]")
  end

  it "indexes into strings with a numeric attribute" do
    _status, output = run_chain_playbook

    output.must_include("[\\\"b\\\"]")
  end
end

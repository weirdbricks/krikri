require "../minitest_helper"

# Real ansible-core 2.19.11's set_fact action plugin (live-verified in the
# krikri repo's output-parity sweep, round sweep10/000016 + probe playbooks):
#
# - `cacheable:` is popped FIRST and run through convert_bool.boolean()
#   with strict=True - any value outside real's BOOLEANS set fails the
#   whole task with
#   "The value '<x>' is not a valid boolean. Valid booleans include: ..."
#   (a plain TypeError: the fatal msg carries the "Task failed: " brief
#   prefix, the [ERROR] block is the single collapsed segment).
# - every remaining KEY is validated with validate_variable_name() in
#   insertion order; the first invalid one fails with
#   "Invalid variable name '<key>'." - an AnsibleError whose cause chain
#   cannot collapse: the block's second segment points at the key's own
#   Origin and carries real's variable-name help text.
# - no key/value pairs at all fails with
#   "No key/value pairs provided, at least one is required for this action
#   to succeed" (an AnsibleActionFail: NO "Task failed: " prefix in the
#   fatal msg).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("set-fact-cacheable", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "set_fact cacheable/keys match real 2.19.11 validation" do
  it "fails a non-boolean cacheable string with real's strict message" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: sf bad
            set_fact:
              cacheable: esfzey
              key_value: zmsyhk
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("[ERROR]: Task failed: The value 'esfzey' is not a valid boolean. Valid booleans include: " +
                        "'off', 1, 'true', 'y', 0, 'false', 'on', 'no', '1', 'yes', '0', 'n', 'f', 't'")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: The value 'esfzey' is not a valid boolean.")
    output.must_include("...ignoring")
    output.must_include("ignored=1")
    # the collapsed shape: no second segment for this failure class
    output.wont_include("<<< caused by >>>")
  end

  it "fails a native int cacheable and a native list cacheable like real" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: sf int
            set_fact:
              cacheable: 5
            ignore_errors: true
          - name: sf list
            set_fact:
              cacheable: []
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("The value '5' is not a valid boolean.")
    output.must_include("The value '[]' is not a valid boolean.")
  end

  it "still accepts a boolean cacheable and stores the facts" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: sf ok
            set_fact:
              cacheable: true
              key_value: zmsyhk
          - debug:
              var: key_value
      YAML

    status.success?.must_equal(true)
    output.must_include("\"key_value\": \"zmsyhk\"")
    output.wont_include("not a valid boolean")
  end

  it "fails an invalid variable-name key with the two-level block and help text" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: sf dotted
            set_fact:
              a.b: xyz
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("[ERROR]: Task failed: Invalid variable name 'a.b'.")
    output.must_include("<<< caused by >>>")
    output.must_include("Invalid variable name 'a.b'.")
    output.must_include("Variable names must be strings starting with a letter or underscore character, and contain only letters, numbers and underscores.")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Invalid variable name 'a.b'.\"}")
  end

  it "fails an empty set_fact with real's no-pairs message (no Task-failed prefix)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: sf empty
            set_fact:
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("[ERROR]: Task failed: No key/value pairs provided, at least one is required for this action to succeed")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"No key/value pairs provided, at least one is required for this action to succeed\"}")
    output.wont_include("Invalid variable name")
  end
end

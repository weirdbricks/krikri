require "../minitest_helper"
require "file_utils"

# ansible.builtin.set_stats' argument validation (issue #897): a typo'd
# option is a module-level fatal on the target - the module's own
# AnsibleModule bootstrap rejects it - rendered as the bare
# "Invalid options for <name>" chain with a changed+msg dump, and
# ignore_errors flips the recap counter to ignored. All shapes
# live-verified against ansible-core 2.19.11 (/tmp minimal repro,
# ansible_connection=local).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_set_stats_playbook(task_body : String)
  dir = File.tempname("set-stats-argspec", ".d")
  Dir.mkdir(dir)
  playbook = File.join(dir, "play.yml")
  indented = task_body.lines.map { |line| line.empty? ? line : "  #{line}" }.join("\n")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n#{indented}\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "ansible.builtin.set_stats argument validation" do
  it "fails a typo'd option with Ansible's Invalid-options wording and ignores it" do
    status, output = run_set_stats_playbook(<<-YAML)
      - name: set_stats typo
        ansible.builtin.set_stats:
          aggregate: true
          data: {}
          per_hots: true
        ignore_errors: true
    YAML

    status.exit_code.must_equal(0)
    output.must_include(%({"changed": false, "msg": "Invalid options for ansible.builtin.set_stats: per_hots"}))
    output.must_include("[ERROR]: Task failed: Invalid options for ansible.builtin.set_stats: per_hots")
    output.must_include("...ignoring")
    output.must_include("ignored=1")
  end

  it "still accepts the real options (data, per_host, aggregate)" do
    status, output = run_set_stats_playbook(<<-YAML)
      - name: set_stats valid
        ansible.builtin.set_stats:
          aggregate: true
          data: {}
          per_host: true
    YAML

    status.exit_code.must_equal(0)
    output.must_include("ok: [localhost]")
    output.wont_include("Invalid options")
  end

  # set_stats is implemented entirely by its ACTION plugin, so a data: value
  # that never becomes a dict is an action-level failure with the plugin's
  # own wording (live-verified vs ansible-core 2.21.6, issue #1241).
  it "fails a non-dictionary data value with the action plugin's wording" do
    status, output = run_set_stats_playbook(<<-YAML)
      - name: set_stats wrong type
        ansible.builtin.set_stats:
          aggregate: true
          data: lfsusj
          per_host: false
        ignore_errors: true
    YAML

    status.exit_code.must_equal(0)
    output.must_include("[ERROR]: Task failed: Action failed: The 'data' option needs to be a dictionary/hash")
    output.must_include(%({"changed": false, "msg": "The 'data' option needs to be a dictionary/hash"}))
    output.must_include("...ignoring")
    output.must_include("ignored=1")
  end

  # The same action plugin defaults an absent data: to {} and never runs a
  # module, so a task with only aggregate:/per_host: succeeds
  # (live-verified vs ansible-core 2.21.6, issue #1241).
  it "succeeds when data is not given at all" do
    status, output = run_set_stats_playbook(<<-YAML)
      - name: set_stats without data
        ansible.builtin.set_stats:
          aggregate: true
    YAML

    status.exit_code.must_equal(0)
    output.must_include("ok: [localhost]")
    output.wont_include("[ERROR]")
  end
end

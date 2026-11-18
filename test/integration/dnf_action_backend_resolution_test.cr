require "../minitest_helper"
require "file_utils"

# End-to-end pin for the dnf/yum ACTION-backend resolution failure
# (round 5310001, kyleabenson.mssql's "Install the EPEL repo rpm" yum: task on
# an Ubuntu 22.04 target). Real 2.19.11's console/fatal output on that host:
#
#   [ERROR]: Task failed: Action failed: ('Could not detect ... dnf5 backend})')
#   fatal: ... {"ansible_facts": {"pkg_mgr": "apt"}, "changed": false,
#               "msg": ["Could not detect ...", "You should ... backend})"]}
#
# krikri used to shell `yum` and fail with a module-level "Failed to install
# packages" instead. The pkg_mgr "fact" is fed as a play var
# (gather_facts: false) so the spec is deterministic on any dev host - the
# plugin resolves its backend from ansible_pkg_mgr however it reached the
# vars context, and the rendered bytes below are identical to the
# gathered-fact path (verified against this engine's real fact gathering).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String, inventory : String = INVENTORY) : {Process::Status, String}
  playbook = File.tempname("dnf-backend", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "dnf/yum action-backend resolution failure end to end (round 5310001)" do
  it "renders the exact Action failed tuple block and fatal msg on a yum task" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_pkg_mgr: apt
        tasks:
          - name: Install the EPEL repo rpm
            yum:
              name: https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
              state: present
      YAML

    # Byte-for-byte vs the round capture, including the error block's
    # Python tuple repr and the stray `})` - a genuine upstream typo.
    output.must_include(
      "[ERROR]: Task failed: Action failed: ('Could not detect which major revision of dnf is in use, " \
      "which is required to determine module backend.', " \
      "'You should manually specify use_backend to tell the module whether to use " \
      "the dnf4 or dnf5 backend})')")
    output.must_include(
      "\"msg\": [\"Could not detect which major revision of dnf is in use, which is required to determine module backend.\", " \
      "\"You should manually specify use_backend to tell the module whether to use the dnf4 or dnf5 backend})\"]")
    output.must_include("failed=1")
    status.success?.must_equal(false)
  end

  # Real's dnf action plugin attaches the pkg_mgr fact it fetched onto the
  # task result only when the task is NOT delegated, or was delegated with
  # delegate_facts: true (`not self._task.delegate_to or
  # self._task.delegate_facts` in plugins/action/dnf.py), and no backend
  # module runs on this failure path - so a plain `delegate_to:` fatal
  # carries no ansible_facts at all (issue #1498's podman diff had krikri
  # adding {"pkg_mgr": "apt"} there).
  it "omits ansible_facts from a delegated dnf fatal without delegate_facts" do
    inventory = PluginSpecHelper.tmp_path("dnf-backend-inv") + ".ini"
    File.write(inventory, "[kpg_targets]\ntarget ansible_connection=local\ntarget2 ansible_connection=local\n")
    _status, output = run_playbook(<<-YAML, inventory)
      - hosts: target
        gather_facts: false
        vars:
          ansible_pkg_mgr: apt
        tasks:
          - name: dnf not delegated
            dnf:
              name: bash
              state: present
            ignore_errors: true
          - name: dnf delegated
            dnf:
              name: bash
              state: present
            delegate_to: target2
            ignore_errors: true
          - name: dnf delegated with delegate_facts
            dnf:
              name: bash
              state: present
            delegate_to: target2
            delegate_facts: true
            ignore_errors: true
      YAML

    tuple = "\"msg\": [\"Could not detect which major revision of dnf is in use, " \
            "which is required to determine module backend.\", " \
            "\"You should manually specify use_backend to tell the module whether to use " \
            "the dnf4 or dnf5 backend})\"]}"
    output.must_include(
      "fatal: [target]: FAILED! => {\"ansible_facts\": {\"pkg_mgr\": \"apt\"}, " \
      "\"changed\": false, #{tuple}")
    # The delegated fatal starts its dict at `changed`: real never ran the
    # backend module, so no module-payload fact can appear either.
    output.must_include("fatal: [target -> target2]: FAILED! => {\"changed\": false, #{tuple}")
    output.must_include(
      "fatal: [target -> target2]: FAILED! => {\"ansible_facts\": {\"pkg_mgr\": \"apt\"}, " \
      "\"changed\": false, #{tuple}")
  end
end

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

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("dnf-backend", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
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
end

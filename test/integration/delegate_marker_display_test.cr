require "file_utils"
require "../minitest_helper"

# The `ok: [source -> target]` delegate marker ansible-playbook prints
# for every delegated task result. Two display sites were missing it:
#
#   * the until:/retries: path (execute_task_with_retries) printed
#     `ok: [h1]` where real prints `ok: [h1 -> localhost]` - found via
#     dockpack.base_goss's own "Get goss binary" task (delegate_to:
#     localhost + until: network_access is success, round 1500188);
#   * tasks inlined by an `import_tasks:` line carrying its own
#     delegate_to: never saw the delegation at all (the import keyword
#     was not propagated to the inlined tasks), so their results printed
#     `ok: [h1]` - found via robertdebock.cups's `import_tasks:
#     assert.yml, delegate_to: localhost` (round 1500129). The marker
#     here is the visible half; the same missing propagation also ran
#     the inlined module against the wrong host for a non-controller
#     target.
#
# A dedicated inventory with a distinct host name (not `localhost`) is
# what makes the marker observable at all: with host == target the
# engines agree by construction.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_with_marker_playbook(yaml : String, inner : String? = nil)
  dir = Dir.tempdir + "/krikri-delegate-marker-#{Random::Secure.hex(4)}"
  FileUtils.mkdir_p(dir)
  inventory = File.join(dir, "inv.ini")
  File.write(inventory, "h1 ansible_connection=local\n")
  playbook = File.join(dir, "play.yml")
  File.write(playbook, yaml)
  if inner
    File.write(File.join(dir, "inner.yml"), inner)
  end

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "delegated result marker ([host -> target])" do
  it "prints the marker for a delegated task with until:/retries:" do
    status, output = run_with_marker_playbook(<<-YAML)
      - hosts: h1
        gather_facts: false
        tasks:
          - name: retried delegated command
            command: echo hi
            delegate_to: localhost
            register: r
            until: r.rc == 0
            retries: 2
            delay: 1
      YAML

    status.exit_code.must_equal(0)
    output.must_match(/changed: \[h1 -> localhost\]/)
    output.wont_match(/changed: \[h1\]\n/)
  end

  it "propagates an import_tasks: line's delegate_to: onto every inlined task" do
    status, output = run_with_marker_playbook(<<-YAML,
      - hosts: h1
        gather_facts: false
        tasks:
          - name: Import inner
            ansible.builtin.import_tasks: inner.yml
            run_once: yes
            delegate_to: localhost
      YAML
      <<-INNER)
        - name: assert inside import
          ansible.builtin.assert:
            that:
              - 1 == 1
      INNER

    status.exit_code.must_equal(0)
    output.must_match(/ok: \[h1 -> localhost\]/)
    output.wont_match(/ok: \[h1\]\n/)
  end
end

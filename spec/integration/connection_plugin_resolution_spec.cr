require "../spec_helper"
require "file_utils"

# Connection-plugin resolution parity, end to end. Real Ansible resolves
# a task's effective connection type (ansible_connection variable or a
# task's own `connection:` keyword) through its plugin loader right
# after the when: evaluates and before the module runs, failing the task
# with "Task failed: the connection plugin 'X' was not found" when
# nothing resolves. The loader's name match is CASE-SENSITIVE (no
# lowercasing anywhere in the resolution path - verified live against
# ansible-core 2.19.11), so "Local"/"Podman" fail exactly like an FQCN
# that names no real connection plugin (community.grafana.grafana is a
# module namespace only).
#
# This engine previously treated ANY non-"local" value as "ssh": an
# unresolvable connection turned into a bogus UNREACHABLE (pre-run
# "Failed to upload ... ssh: connect refused", or "Failed to connect to
# the host via ssh") instead of real Ansible's one clean failed task.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String, extra_args : Array(String) = [] of String) : {Process::Status, String}
  playbook = File.tempname("connection-type", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + extra_args + [playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unresolvable connection type fails the task like real Ansible" do
  %w[
    community.grafana.grafana
    Podman
    Local
    LOCAL
    bogusconnection
  ].each do |conn_type|
    it "fails the task (not unreachable) for ansible_connection #{conn_type} set on the host" do
      status, output = run_playbook(<<-YAML, ["-c", conn_type])
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: ordinary task
              ansible.builtin.debug:
                msg: hi
        YAML
      status.success?.should be_false, output
      output.should contain("the connection plugin '#{conn_type}' was not found"), output
      output.should contain("PLAY RECAP"), output
      output.should contain("failed=1"), output
      output.should_not contain("unreachable=1"), output
      output.should_not contain("Failed to upload"), output
    end
  end

  it "fails via a task-level connection: override too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: task-level bad connection
            ansible.builtin.debug:
              msg: hi
            connection: community.grafana.grafana
      YAML
    status.success?.should be_false, output
    output.should contain("the connection plugin 'community.grafana.grafana' was not found"), output
  end

  it "still fails Gathering Facts (not unreachable) when the play gathers facts" do
    status, output = run_playbook(<<-YAML, ["-c", "community.grafana.grafana"])
      - hosts: localhost
        gather_facts: true
        tasks:
          - name: never reached
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.should be_false, output
    output.should contain("the connection plugin 'community.grafana.grafana' was not found"), output
    output.should_not contain("unreachable=1"), output
  end

  it "keeps the SSH fallback for a collection connection plugin that IS installed on the controller" do
    # containers.podman.podman is a real connection plugin the controller's
    # collection path resolves - real Ansible would exec the module
    # inside the container; this engine keeps its long-standing SSH
    # transport approximation for that case (a resolution failure would
    # be a REGRESSION for roles relying on the fallback), so this only
    # pins "not treated as not-found", observable via the error shape
    # being the SSH one, never the "was not found" one. Skipped when the
    # collection isn't installed on this controller.
    unless File.exists?(File.join(ENV["HOME"], ".ansible", "collections",
      "ansible_collections", "containers", "podman", "plugins", "connection", "podman.py"))
      puts "skipping: containers.podman not installed on this controller"
      next
    end
    status, output = run_playbook(<<-YAML, ["-c", "containers.podman.podman"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    output.should_not contain("was not found"), output
  end
end

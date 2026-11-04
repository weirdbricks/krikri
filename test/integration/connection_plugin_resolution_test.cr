require "../minitest_helper"
require "file_utils"

# Connection-plugin resolution parity, end to end. Ansible resolves
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
# the host via ssh") instead of Ansible's one clean failed task.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String, extra_args : Array(String) = [] of String) : {Process::Status, String}
  playbook = File.tempname("connection-type", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + extra_args + [playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unresolvable connection type fails the task like Ansible" do
  # minitest's describe/it macros cannot expand inside a runtime block,
  # and `it` names cannot interpolate, so the classic suite's conn_type
  # loop is unrolled into one static it per connection type.
  it "fails the task (not unreachable) for ansible_connection community.grafana.grafana set on the host" do
    status, output = run_playbook(<<-YAML, ["-c", "community.grafana.grafana"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'community.grafana.grafana' was not found", output)
    output.must_include("PLAY RECAP", output)
    output.must_include("failed=1", output)
    output.wont_include("unreachable=1", output)
    output.wont_include("Failed to upload", output)
  end

  it "fails the task (not unreachable) for ansible_connection Podman set on the host" do
    status, output = run_playbook(<<-YAML, ["-c", "Podman"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'Podman' was not found", output)
    output.must_include("PLAY RECAP", output)
    output.must_include("failed=1", output)
    output.wont_include("unreachable=1", output)
    output.wont_include("Failed to upload", output)
  end

  it "fails the task (not unreachable) for ansible_connection Local set on the host" do
    status, output = run_playbook(<<-YAML, ["-c", "Local"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'Local' was not found", output)
    output.must_include("PLAY RECAP", output)
    output.must_include("failed=1", output)
    output.wont_include("unreachable=1", output)
    output.wont_include("Failed to upload", output)
  end

  it "fails the task (not unreachable) for ansible_connection LOCAL set on the host" do
    status, output = run_playbook(<<-YAML, ["-c", "LOCAL"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'LOCAL' was not found", output)
    output.must_include("PLAY RECAP", output)
    output.must_include("failed=1", output)
    output.wont_include("unreachable=1", output)
    output.wont_include("Failed to upload", output)
  end

  it "fails the task (not unreachable) for ansible_connection bogusconnection set on the host" do
    status, output = run_playbook(<<-YAML, ["-c", "bogusconnection"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'bogusconnection' was not found", output)
    output.must_include("PLAY RECAP", output)
    output.must_include("failed=1", output)
    output.wont_include("unreachable=1", output)
    output.wont_include("Failed to upload", output)
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
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'community.grafana.grafana' was not found", output)
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
    status.success?.must_equal(false, output)
    output.must_include("the connection plugin 'community.grafana.grafana' was not found", output)
    output.wont_include("unreachable=1", output)
  end

  it "keeps the SSH fallback for a collection connection plugin that IS installed on the controller" do
    # containers.podman.podman is a real connection plugin the controller's
    # collection path resolves - Ansible would exec the module
    # inside the container; this engine keeps its long-standing SSH
    # transport approximation for that case (a resolution failure would
    # be a REGRESSION for roles relying on the fallback), so this only
    # pins "not treated as not-found", observable via the error shape
    # being the SSH one, never the "was not found" one. Skipped when the
    # collection isn't installed on this controller.
    # crystal spec's bare `next` has no minitest equivalent inside a def;
    # skip raises Minitest::Skip instead.
    skip "containers.podman not installed on this controller" unless File.exists?(File.join(ENV["HOME"], ".ansible", "collections",
                                                                       "ansible_collections", "containers", "podman", "plugins", "connection", "podman.py"))
    _status, output = run_playbook(<<-YAML, ["-c", "containers.podman.podman"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    output.wont_include("was not found", output)
  end
end

# Ansible compiles a play's static roles (and merges their
# defaults/main.yml into the play's var stack) before ANY task runs, the
# implicit Gathering Facts task included. Network roles live on this:
# vinealvees.general_configs (issue #811) sets
# `ansible_connection: network_cli` + `ansible_network_os: ios` in its
# own defaults, so Ansible's smart gather resolves the ios facts module
# over the network connection and fails Gathering Facts fatally - the
# play stops, no role task ever runs. This engine's gather used to see
# only the host's own vars: it ssh'd out, booked ok=1, and then ran the
# role's first task (failing there with the same not-found message), so
# a task ran on krikri that Ansible never reached.
describe "role-default connection leak reaches the implicit gather" do
  # A fresh root per call: the suite's worker fibers run sibling tests
  # concurrently, and the role's defaults file differs per test.
  private def run_leak_play(playbook : String, defaults : String = "---\nansible_connection: network_cli\nansible_network_os: ios\n") : {Process::Status, String}
    root = File.tempname("connleak")
    Dir.mkdir_p(root)
    role = File.join(root, "roles", "leaky")
    Dir.mkdir_p(File.join(role, "defaults"))
    Dir.mkdir_p(File.join(role, "tasks"))
    File.write(File.join(role, "defaults", "main.yml"), defaults)
    File.write(File.join(role, "tasks", "main.yml"),
      "---\n- name: never reached\n  ansible.builtin.debug:\n    msg: hi\n")
    File.write(File.join(root, "inv.ini"), "target ansible_host=127.0.0.1 ansible_port=2299\n")
    File.write(File.join(root, "pb.yml"), playbook)
    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: captured, error: captured, chdir: root)
    {status, captured.to_s}
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end

  it "fails Gathering Facts (fatal, play stops) when a role default leaks network_cli" do
    status, output = run_leak_play(<<-YAML)
      - hosts: target
        become: true
        gather_facts: true
        roles:
          - leaky
      YAML
    status.success?.must_equal(false, output)
    output.must_include("TASK [Gathering Facts]", output)
    output.must_include("the connection plugin 'network_cli' was not found", output)
    output.must_include("failed=1", output)
    output.wont_include("ok=1", output)
    output.wont_include("never reached", output)
  end

  it "fails Gathering Facts for the play's own connection: keyword too" do
    status, output = run_leak_play(<<-YAML)
      - hosts: target
        gather_facts: true
        connection: boguskeyword
        tasks:
          - name: never reached
            ansible.builtin.debug:
              msg: hi
      YAML
    status.success?.must_equal(false, output)
    output.must_include("TASK [Gathering Facts]", output)
    output.must_include("the connection plugin 'boguskeyword' was not found", output)
    output.must_include("failed=1", output)
    output.wont_include("never reached", output)
  end

  it "still gathers normally when a role default leaks a resolvable connection (local)" do
    status, output = run_leak_play(<<-YAML, defaults: "---\nansible_connection: local\n")
      - hosts: target
        gather_facts: true
        roles:
          - leaky
      YAML
    status.success?.must_equal(true, output)
    output.must_include("never reached", output)
    output.wont_include("was not found", output)
  end
end

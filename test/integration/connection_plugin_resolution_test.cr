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

  it "fails a collection connection plugin that IS installed on the controller, naming it as unexecutable" do
    # containers.podman.podman is a real connection plugin the controller's
    # collection path resolves - Ansible would exec the module inside the
    # container. This engine cannot run that plugin's transport, so the
    # task fails naming the plugin as unexecutable: treated as RESOLVED
    # (never as "was not found", the #1457 regression), but never run
    # over the SSH fallback either (#1541, #1658). Skipped when the
    # collection isn't installed on this controller.
    # crystal spec's bare `next` has no minitest equivalent inside a def;
    # skip raises Minitest::Skip instead.
    skip "containers.podman not installed on this controller" unless File.exists?(File.join(ENV["HOME"], ".ansible", "collections",
                                                                       "ansible_collections", "containers", "podman", "plugins", "connection", "podman.py"))
    status, output = run_playbook(<<-YAML, ["-c", "containers.podman.podman"])
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: ordinary task
            ansible.builtin.debug:
              msg: hi
      YAML
    output.wont_include("was not found", output)
    status.success?.must_equal(false, output)
    output.must_include("Task failed: the connection plugin 'containers.podman.podman' cannot be executed by krikri-playbook", output)
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

# Ansible's connection loader also searches every plugin directory the run
# registers: the playbook-adjacent `connection_plugins/`, each loaded
# role's own, then ANSIBLE_CONNECTION_PLUGINS (which REPLACES the
# configured defaults). A Python connection plugin Ansible finds there IS
# a resolution success (issue #1457 fixed the false "the connection plugin
# 'mylocal' was not found"), but this engine still cannot run the plugin's
# own connection lifecycle, so the task fails with the plugin named as
# unexecutable instead of running over a substituted transport (issues
# #1541, #1658). Ansible itself runs the same play ok=1.
describe "custom Python connection plugins on Ansible's loader paths" do
  private def local_wrapper_plugin : String
    <<-PYTHON
      from ansible.plugins.connection.local import Connection as LocalConnection

      DOCUMENTATION = """
          name: mylocal
          short_description: local connection wrapper
          options: {}
      """


      class Connection(LocalConnection):
          transport = "mylocal"
      PYTHON
  end

  private def ssh_wrapper_plugin : String
    <<-PYTHON
      from ansible.plugins.connection.ssh import Connection as SSHConnection

      DOCUMENTATION = """
          name: myssh
          short_description: ssh connection wrapper
          options: {}
      """


      class Connection(SSHConnection):
          transport = "myssh"
      PYTHON
  end

  # Builds a throwaway playbook tree and runs *playbook* against it.
  # `plugins_next_to_playbook` puts connection_plugins/ beside the
  # playbook (no env var, Ansible's basedir registration);
  # ANSIBLE_CONNECTION_PLUGINS names it otherwise. A fresh HOME keeps the
  # controller's own plugins/connection out of the search path.
  private def run_custom_connection_play(plugins_next_to_playbook : Bool,
                                         plugin : String = local_wrapper_plugin,
                                         plugin_name : String = "mylocal",
                                         gather_facts : Bool = false) : {Process::Status, String}
    root = File.tempname("custom-connection-plugin")
    Dir.mkdir_p(root)
    home = File.join(root, "home")
    Dir.mkdir_p(home)
    playbook_dir = plugins_next_to_playbook ? File.join(root, "playbooks") : root
    plugin_dir = File.join(playbook_dir, "connection_plugins")
    Dir.mkdir_p(plugin_dir)
    File.write(File.join(plugin_dir, "#{plugin_name}.py"), plugin)
    File.write(File.join(root, "inv.ini"), "[all]\nhost1 ansible_connection=#{plugin_name}\n")
    playbook = File.join(playbook_dir, "pb.yml")
    File.write(playbook, "- hosts: all\n  gather_facts: #{gather_facts}\n  tasks:\n    - ansible.builtin.ping:\n")

    env = {
      "PATH" => ENV["PATH"]? || "/usr/local/bin:/usr/bin:/bin",
      "HOME" => home,
    }
    unless plugins_next_to_playbook
      env["ANSIBLE_CONNECTION_PLUGINS"] = plugin_dir
    end

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(root, "inv.ini"), "-T", "5", playbook],
      output: captured, error: captured, env: env)
    {status, captured.to_s}
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end

  it "fails a local-wrapper plugin found through ANSIBLE_CONNECTION_PLUGINS, naming it as unexecutable" do
    status, output = run_custom_connection_play(plugins_next_to_playbook: false)
    output.wont_include("was not found", output)
    status.success?.must_equal(false, output)
    output.must_include("Task failed: the connection plugin 'mylocal' cannot be executed by krikri-playbook", output)
    output.must_include("failed=1", output)
    output.wont_include("ok: [host1]", output)
    output.wont_include("UNREACHABLE", output)
  end

  it "fails a local-wrapper plugin from the playbook-adjacent connection_plugins/ the same way" do
    status, output = run_custom_connection_play(plugins_next_to_playbook: true)
    output.wont_include("was not found", output)
    status.success?.must_equal(false, output)
    output.must_include("Task failed: the connection plugin 'mylocal' cannot be executed by krikri-playbook", output)
    output.must_include("failed=1", output)
  end

  # The implicit gather reads the host's vars plus the play's role layers,
  # not a task's full context, so it has no `playbook_dir` magic var to
  # search the playbook-adjacent connection_plugins/ with. Without the
  # executor's own playbook dir as a fallback a plugin Ansible resolves
  # reads as "was not found" there - the #1457 false negative again, this
  # time before the first task (issue #1658).
  it "names a playbook-adjacent plugin as unexecutable during the implicit gather too" do
    status, output = run_custom_connection_play(plugins_next_to_playbook: true, gather_facts: true)
    output.wont_include("was not found", output)
    status.success?.must_equal(false, output)
    output.must_include("Task failed: the connection plugin 'mylocal' cannot be executed by krikri-playbook", output)
    output.must_include("failed=1", output)
  end

  # A plugin that is not a local wrapper would otherwise have its task
  # run over SSH: the class-implied transport is only a guess, and it is
  # the guess that made #1541's SSM-style plugin ssh to its instance id.
  it "fails a resolved plugin that is not a local connection instead of substituting SSH" do
    status, output = run_custom_connection_play(plugins_next_to_playbook: false,
      plugin: ssh_wrapper_plugin, plugin_name: "myssh")
    output.wont_include("was not found", output)
    status.success?.must_equal(false, output)
    output.must_include("Task failed: the connection plugin 'myssh' cannot be executed by krikri-playbook", output)
    output.must_include("failed=1", output)
    output.wont_include("UNREACHABLE", output)
    output.wont_include("unreachable=1", output)
  end

  # Issue #1658's repro: the plugin writes a marker in its own __init__,
  # so real ansible-playbook (which constructs the plugin) creates it.
  # This engine neither runs the plugin nor pretends to: the marker must
  # stay absent AND the run must fail naming the plugin, rather than
  # booking an ok for a task that never reached the plugin's transport.
  it "does not run the plugin's own code, and fails instead of booking ok" do
    marker = File.tempname("krikri-conn-marker")
    plugin = <<-PYTHON
      from ansible.plugins.connection.local import Connection as LocalConnection

      DOCUMENTATION = """
          name: marker
          short_description: local wrapper that writes a marker
          options: {}
      """


      class Connection(LocalConnection):
          transport = "marker"

          def __init__(self, *a, **k):
              open("#{marker}", "w").write("x")
              super().__init__(*a, **k)
      PYTHON
    status, output = run_custom_connection_play(plugins_next_to_playbook: false,
      plugin: plugin, plugin_name: "marker")
    File.exists?(marker).must_equal(false, "the plugin's own code ran: #{output}")
    status.success?.must_equal(false, output)
    output.must_include("Task failed: the connection plugin 'marker' cannot be executed by krikri-playbook", output)
    output.wont_include("ok: [host1]", output)
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end

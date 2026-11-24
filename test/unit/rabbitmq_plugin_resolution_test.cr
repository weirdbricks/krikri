require "../minitest_helper"
require "file_utils"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# The rabbitmq_plugin plugin binary has existed since round 196, but both
# real-world roles that use it (SimpliField.rabbitmq round 300127,
# rockandska.rabbitmq round 310088) write the bare short name
# `rabbitmq_plugin:` with the Ansible module's `names:` argument - the bare
# name didn't resolve (community.rabbitmq was missing from the collection
# search list) and the plugin only read a `name` param, so the task
# hard-stopped as "unavailable module". Cross-checks the resolution and
# the parser search list.
private def single_task(task_yaml : String) : Krikri::Task
  task_block = task_yaml.strip.lines.map { |line| "    #{line}" }.join("\n")
  playbook_yaml = "- name: Loop test play\n  hosts: all\n  tasks:\n#{task_block}\n"
  playbook = Krikri::PlaybookParser.parse_string(playbook_yaml)
  playbook.plays[0].tasks[0]
end

describe "community.rabbitmq short names" do
  {% for short_name in %w[rabbitmq_plugin rabbitmq_user] %}
    it "resolves bare `{{short_name.id}}:` to community.rabbitmq.{{short_name.id}}" do
      task = single_task(<<-YAML)
        - name: t
          {{short_name.id}}: {}
        YAML
      task.module_name.must_equal("community.rabbitmq.{{short_name.id}}")
    end
  {% end %}

  it "still resolves the fully-qualified spelling" do
    task = single_task(<<-YAML)
      - name: t
        community.rabbitmq.rabbitmq_plugin: {}
      YAML
    task.module_name.must_equal("community.rabbitmq.rabbitmq_plugin")
  end

  it "maps the FQCNs to the existing plugin binaries" do
    Krikri::PluginManager.simple_plugin_name("community.rabbitmq.rabbitmq_plugin").must_equal("rabbitmq_plugin")
    Krikri::PluginManager.simple_plugin_name("community.rabbitmq.rabbitmq_user").must_equal("rabbitmq_user")
  end
end

# rabbitmq_plugin.py declares supports_check_mode=True and funnels every
# rabbitmq-plugins invocation through _exec(), which only runs the command
# when not in check mode - the `list -E -m` probe is the one exception
# (force_exec_in_check_mode=True). The requested names still land in
# enabled/disabled, so check mode predicts `changed` for a plugin the
# broker does not even ship; krikri ran the enable for real and failed the
# task (#1751).
private def rabbitmq_plugin_1751_logging_shim(dir : String) : {String, String}
  log = File.join(dir, "invocations.log")
  shim = File.join(dir, "rabbitmq-plugins")
  File.write(shim, <<-SH)
    #!/bin/sh
    printf '%s\\n' "$*" >> #{Process.quote(log)}
    if [ "$1" = "list" ]; then
      printf 'rabbitmq_management\\n'
      exit 0
    fi
    exit 0
    SH
  File.chmod(shim, 0o755)
  {dir, log}
end

describe "rabbitmq_plugin check mode" do
  it "reports changed without running enable for a missing plugin" do
    shim_dir = PluginSpecHelper.tmp_path("shims")
    Dir.mkdir_p(shim_dir)
    _, log = rabbitmq_plugin_1751_logging_shim(shim_dir)

    result = PluginSpecHelper.run("rabbitmq_plugin", {
      "names"               => "wufeut",
      "new_only"            => "true",
      "state"               => "enabled",
      "_ansible_check_mode" => "true",
    }, env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]?}"})

    result["changed"].as_bool.must_equal(true)
    result["enabled"].as_a.map(&.as_s).must_equal(["wufeut"])
    result["disabled"].as_a.map(&.as_s).must_equal([] of String)
    File.read(log).must_equal("list -E -m\n")
  end

  it "still runs enable outside check mode" do
    shim_dir = PluginSpecHelper.tmp_path("shims")
    Dir.mkdir_p(shim_dir)
    _, log = rabbitmq_plugin_1751_logging_shim(shim_dir)

    result = PluginSpecHelper.run("rabbitmq_plugin", {
      "names"               => "wufeut",
      "new_only"            => "true",
      "state"               => "enabled",
      "_ansible_check_mode" => "false",
    }, env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]?}"})

    result["changed"].as_bool.must_equal(true)
    # The module always passes --<broker_state> to enable/disable.
    File.read(log).must_equal("list -E -m\nenable --online wufeut\n")
  end
end

# The module's wire result, pinned against community.rabbitmq's own code paths
# (live-verified on this host: ansible-core 2.21.6 + community.rabbitmq).
# Issue #1752: a failing `rabbitmq-plugins enable` reported a krikri-authored
# "Failed to enable plugin X: ..." msg and dropped the command's own output,
# where the module's run_command(check_rc=True) fails with the bare rstripped
# stderr plus cmd/rc/stdout/stderr; a successful task returns only
# changed/enabled/disabled, exit_json adding no msg.
describe "rabbitmq_plugin module result" do
  # Stands in for the daemon CLI: `list -E -m` reports two enabled plugins,
  # `enable okplugin` succeeds, and every other enable reproduces the issue's
  # failing broker ("plugins_not_found" on stderr, rc 70).
  RABBITMQ_PLUGINS_SHIM = <<-'SHIM'
    #!/bin/bash
    case "$1" in
      list)
        printf 'rabbitmq_management\nrabbitmq_management_agent\n' ;;
      enable)
        echo "Enabling plugins on node rabbit@ubuntu:"
        echo "$3"
        if [ "$3" != "okplugin" ]; then
          echo "Error:" >&2
          echo "{:plugins_not_found, [:$3]}" >&2
          exit 70
        fi ;;
      disable)
        echo "Disabling plugins on node rabbit@ubuntu:"
        echo "$3" ;;
    esac
    exit 0
    SHIM

  private def install_shim(path : String) : Nil
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, RABBITMQ_PLUGINS_SHIM)
    File.chmod(path, 0o755)
  end

  private def with_rabbitmq_shim(&)
    dir = PluginSpecHelper.tmp_path("rabbitmq-shim")
    bin_dir = File.join(dir, "bin")
    install_shim(File.join(bin_dir, "rabbitmq-plugins"))
    yield bin_dir
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  it "reports a failed rabbitmq-plugins call as basic.py's check_rc failure" do
    with_rabbitmq_shim do |bin_dir|
      result = PluginSpecHelper.run("rabbitmq_plugin", {
        "names"        => "wufeut",
        "new_only"     => "true",
        "state"        => "enabled",
        "broker_state" => "online",
      }, env: {"PATH" => "#{bin_dir}:/usr/bin:/bin"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Error:\n{:plugins_not_found, [:wufeut]}")
      result["rc"].as_i.must_equal(70)
      result["cmd"].as_s.must_equal("#{bin_dir}/rabbitmq-plugins enable --online wufeut")
      result["stdout"].as_s.must_equal("Enabling plugins on node rabbit@ubuntu:\nwufeut\n")
      result["stdout_lines"].as_a.map(&.as_s).must_equal(["Enabling plugins on node rabbit@ubuntu:", "wufeut"])
      result["stderr"].as_s.must_equal("Error:\n{:plugins_not_found, [:wufeut]}\n")
      result["stderr_lines"].as_a.map(&.as_s).must_equal(["Error:", "{:plugins_not_found, [:wufeut]}"])
    end
  end

  it "returns enabled/disabled and no msg on success" do
    with_rabbitmq_shim do |bin_dir|
      env = {"PATH" => "#{bin_dir}:/usr/bin:/bin"}

      # new_only=false on a broker listing two plugins: both are disabled
      # first, then the requested one is enabled.
      result = PluginSpecHelper.run("rabbitmq_plugin", {"names" => "okplugin"}, env: env)
      result["changed"].as_bool.must_equal(true)
      result["enabled"].as_a.map(&.as_s).must_equal(["okplugin"])
      result["disabled"].as_a.map(&.as_s).must_equal(["rabbitmq_management", "rabbitmq_management_agent"])
      result.as_h.has_key?("msg").must_equal(false)

      # state=disabled keeps the ones outside names enabled, and the disable
      # call carries the broker_state flag like the module's.
      disabled = PluginSpecHelper.run("rabbitmq_plugin", {
        "names"        => "rabbitmq_management",
        "state"        => "disabled",
        "broker_state" => "offline",
      }, env: env)
      disabled["changed"].as_bool.must_equal(true)
      disabled["enabled"].as_a.must_equal([] of JSON::Any)
      disabled["disabled"].as_a.map(&.as_s).must_equal(["rabbitmq_management"])
      disabled.as_h.has_key?("msg").must_equal(false)
    end
  end

  it "fails with get_bin_path's wording when rabbitmq-plugins is nowhere" do
    dir = PluginSpecHelper.tmp_path("rabbitmq-missing")
    begin
      empty = File.join(dir, "empty")
      FileUtils.mkdir_p(empty)
      # /usr/bin:/bin keep the probe's own helpers reachable; neither carries
      # a rabbitmq-plugins.
      path = "#{empty}:/usr/bin:/bin"
      result = PluginSpecHelper.run("rabbitmq_plugin", {"names" => "wufeut"}, env: {"PATH" => path})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.starts_with?(
        %(Failed to find required executable "rabbitmq-plugins" in paths: #{path})).must_equal(true, result["msg"].as_s)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "takes the binary from <prefix>/bin or <prefix>/sbin, and fails without either" do
    dir = PluginSpecHelper.tmp_path("rabbitmq-prefix")
    begin
      bin_dir = File.join(dir, "rabbitmq", "bin")
      install_shim(File.join(bin_dir, "rabbitmq-plugins"))

      result = PluginSpecHelper.run("rabbitmq_plugin", {
        "names"  => "wufeut",
        "prefix" => File.join(dir, "rabbitmq"),
      }, env: {"PATH" => "/usr/bin:/bin"})
      result["failed"].as_bool.must_equal(true)
      result["cmd"].as_s.must_equal("#{bin_dir}/rabbitmq-plugins enable --online wufeut")

      missing = PluginSpecHelper.run("rabbitmq_plugin", {
        "names"  => "wufeut",
        "prefix" => File.join(dir, "noprefix"),
      }, env: {"PATH" => "/usr/bin:/bin"})
      missing["failed"].as_bool.must_equal(true)
      missing["msg"].as_s.must_equal("No binary folder in prefix #{dir}/noprefix")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports what it would change under check mode without running anything" do
    with_rabbitmq_shim do |bin_dir|
      # The shim exits 70 on every enable, exactly like the issue's broker, so
      # a check-mode run that invoked the CLI would fail instead of reporting.
      result = PluginSpecHelper.run("rabbitmq_plugin", {
        "names"               => "wufeut",
        "new_only"            => "true",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => "#{bin_dir}:/usr/bin:/bin"})

      result.as_h.has_key?("failed").must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["enabled"].as_a.map(&.as_s).must_equal(["wufeut"])
      result["disabled"].as_a.must_equal([] of JSON::Any)
    end
  end
end

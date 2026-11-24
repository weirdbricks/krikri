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
    File.read(log).must_equal("list -E -m\nenable wufeut\n")
  end
end

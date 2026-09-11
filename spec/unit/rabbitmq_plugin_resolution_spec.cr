require "../spec_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# The rabbitmq_plugin plugin binary has existed since round 196, but both
# real-world roles that use it (SimpliField.rabbitmq round 300127,
# rockandska.rabbitmq round 310088) write the bare short name
# `rabbitmq_plugin:` with the real module's `names:` argument - the bare
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
  %w[rabbitmq_plugin rabbitmq_user].each do |short_name|
    it "resolves bare `#{short_name}:` to community.rabbitmq.#{short_name}" do
      task = single_task(<<-YAML)
        - name: t
          #{short_name}: {}
        YAML
      task.module_name.should eq("community.rabbitmq.#{short_name}")
    end
  end

  it "still resolves the fully-qualified spelling" do
    task = single_task(<<-YAML)
      - name: t
        community.rabbitmq.rabbitmq_plugin: {}
      YAML
    task.module_name.should eq("community.rabbitmq.rabbitmq_plugin")
  end

  it "maps the FQCNs to the existing plugin binaries" do
    Krikri::PluginManager.simple_plugin_name("community.rabbitmq.rabbitmq_plugin").should eq("rabbitmq_plugin")
    Krikri::PluginManager.simple_plugin_name("community.rabbitmq.rabbitmq_user").should eq("rabbitmq_user")
  end
end

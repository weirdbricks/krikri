require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# ansible-core 2.21's community.mysql is a redirect-only shell: the
# collection moved to ansible.mysql, so real ansible ships (and
# ansible-doc lists) ansible.mysql.mysql_variables. The registry carried
# only the community.mysql spelling, so a playbook written under the
# namespace real ships dropped the task as "uses unimplemented plugin"
# and the generator's module rotation could never exercise it.
describe "ansible.mysql.mysql_variables namespace" do
  {% for spelling in ["ansible.mysql.mysql_variables", "community.mysql.mysql_variables"] %}
    it "resolves {{ spelling.id }}: to the mysql_variables plugin, not an unavailable module" do
      playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: read a variable
              {{ spelling.id }}:
                login_user: root
                variable: version
        YAML
      task = playbook.plays[0].tasks[0]
      task.unavailable_module.must_be_nil
      Krikri::PluginManager.simple_plugin_name(task.module_name).must_equal("mysql_variables")
    end
  {% end %}
end

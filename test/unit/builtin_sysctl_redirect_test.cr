require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# `ansible.builtin.sysctl:` must resolve to the implemented sysctl
# plugin binary, exactly like the `ansible.posix.sysctl` spelling -
# ansible-core's own ansible_builtin_runtime.yml transparently
# redirects the builtin spelling (sysctl moved to ansible.posix years
# ago, same shape as mount/acl/authorized_key before it). Without the
# registry entry the task was dropped as an unavailable module and
# silently skipped (artem_shestakov.nginx round 5214000: real ran the
# task, krikri skipped it and exited 4).
describe "ansible.builtin.sysctl legacy redirect" do
  {% for spelling in ["ansible.builtin.sysctl", "ansible.posix.sysctl"] %}
    it "resolves {{spelling.id}}: to the sysctl plugin, not an unavailable module" do
      playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: set sysctl
              {{spelling.id}}:
                name: net.ipv4.ip_nonlocal_bind
                value: 1
        YAML
      task = playbook.plays[0].tasks[0]
      task.unavailable_module.must_be_nil
      Krikri::PluginManager.simple_plugin_name(task.module_name).must_equal("sysctl")
    end
  {% end %}
end

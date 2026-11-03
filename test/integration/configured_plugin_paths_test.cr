require "../minitest_helper"
require "file_utils"

# Custom filter/test/action plugins living in Ansible's configured plugin
# trees - ANSIBLE_<TYPE>_PLUGINS and ~/.ansible/plugins/<type> - must
# resolve exactly as they do under ansible-playbook (issue #793; #778 fixed
# only the lookup side). Each case runs the real binary end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private PS_INVENTORY = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def ps_run(dir : String, overrides : Hash(String, String)) : {String, Process::Status}
  output = IO::Memory.new
  env = ENV.to_h.merge(overrides)
  status = Process.run(BINARY, ["-i", PS_INVENTORY, "pb.yml"],
    output: output, error: output, chdir: dir, env: env)
  {output.to_s, status}
end

describe "configured plugin dirs resolve custom plugins (issue #793)" do
  it "resolves a filter, a test and an action plugin from the ANSIBLE_*_PLUGINS lists" do
    root = PluginSpecHelper.tmp_path("configured-plugins-env")
    filter_dir = File.join(root, "filter")
    test_dir = File.join(root, "test")
    action_dir = File.join(root, "action")
    {filter_dir, test_dir, action_dir}.each { |dir| Dir.mkdir_p(dir) }

    File.write(File.join(filter_dir, "myfilters.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"shout": lambda x: str(x).upper() + "!"}
      PYTHON
    File.write(File.join(test_dir, "mytests.py"), <<-PYTHON)
      class TestModule(object):
          def tests(self):
              return {"oddly_odd": lambda x: True}
      PYTHON
    File.write(File.join(action_dir, "myaction.py"), <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              result['changed'] = False
              result['msg'] = 'hello from myaction'
              return result
      PYTHON

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ 'hi' | shout }}"
          - debug:
              msg: "{{ 3 is oddly_odd }}"
          - myaction:
      YAML

    output, status = ps_run(root, {
      "ANSIBLE_FILTER_PLUGINS" => filter_dir,
      "ANSIBLE_TEST_PLUGINS"   => test_dir,
      "ANSIBLE_ACTION_PLUGINS" => action_dir,
      "HOME"                   => File.join(root, "home"),
    })
    status.success?.must_equal(true)
    (output.includes?("\"msg\": \"HI!\"")).must_equal(true)
    (output.includes?("\"msg\": true")).must_equal(true)
    (output.includes?("ok=3")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end

  it "falls back to ~/.ansible/plugins/<type> when no env var is set" do
    root = PluginSpecHelper.tmp_path("configured-plugins-home")
    home = File.join(root, "home")
    Dir.mkdir_p(File.join(home, ".ansible", "plugins", "filter"))
    Dir.mkdir_p(File.join(home, ".ansible", "plugins", "test"))
    File.write(File.join(home, ".ansible", "plugins", "filter", "myfilters.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"shout": lambda x: str(x).upper() + "!"}
      PYTHON
    File.write(File.join(home, ".ansible", "plugins", "test", "mytests.py"), <<-PYTHON)
      class TestModule(object):
          def tests(self):
              return {"oddly_odd": lambda x: True}
      PYTHON

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ 'hi' | shout }}"
          - debug:
              msg: "{{ 3 is oddly_odd }}"
      YAML

    output, status = ps_run(root, {"HOME" => home})
    status.success?.must_equal(true)
    (output.includes?("\"msg\": \"HI!\"")).must_equal(true)
    (output.includes?("\"msg\": true")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end

  it "lets the playbook-adjacent plugin dir win over a configured one" do
    root = PluginSpecHelper.tmp_path("configured-plugins-precedence")
    configured = File.join(root, "configured")
    Dir.mkdir_p(configured)
    Dir.mkdir_p(File.join(root, "filter_plugins"))
    File.write(File.join(configured, "cf.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"who": lambda x: "CONFIGURED"}
      PYTHON
    File.write(File.join(root, "filter_plugins", "pf.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"who": lambda x: "PLAYBOOK"}
      PYTHON

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ 1 | who }}"
      YAML

    output, status = ps_run(root, {
      "ANSIBLE_FILTER_PLUGINS" => configured,
      "HOME"                   => File.join(root, "home"),
    })
    status.success?.must_equal(true)
    (output.includes?("\"msg\": \"PLAYBOOK\"")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end
end

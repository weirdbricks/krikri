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

# The vars-plugin cases put their own inventory next to the playbook, so
# host_vars/ resolves against the playbook's directory (as it does for
# ansible-playbook) and HOME never leaks the developer's real
# ~/.ansible/plugins/vars into the run.
private def ps_run_vars(dir : String, overrides : Hash(String, String)) : {String, Process::Status}
  output = IO::Memory.new
  env = ENV.to_h.merge({"HOME" => File.join(dir, "home")})
  {"ANSIBLE_VARS_PLUGINS", "ANSIBLE_VARS_ENABLED", "ANSIBLE_HOME"}.each { |key| env.delete(key) }
  env.merge!(overrides)
  status = Process.run(BINARY, ["-i", File.join(dir, "inv.ini"), "pb.yml"],
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

  # issue #1474: a VarsModule's get_vars() was never called, so every
  # variable it returned was silently undefined.
  it "runs a custom vars plugin from the ANSIBLE_VARS_PLUGINS list" do
    root = PluginSpecHelper.tmp_path("configured-plugins-vars")
    vars_dir = File.join(root, "vars")
    Dir.mkdir_p(vars_dir)
    File.write(File.join(vars_dir, "myvars.py"), <<-PYTHON)
      from ansible.plugins.vars import BaseVarsPlugin

      DOCUMENTATION = """
          name: myvars
          short_description: demo vars plugin
          options: {}
      """


      class VarsModule(BaseVarsPlugin):
          REQUIRES_ENABLED = False

          def get_vars(self, loader, path, entities, cache=True):
              return {"vars_plugin_var": "present", "vars_plugin_file_var": "plugin"}
      PYTHON
    # A host_vars file value outranks a legacy vars plugin's own (ansible
    # runs the builtin host_group_vars after the legacy plugins).
    Dir.mkdir_p(File.join(root, "host_vars"))
    File.write(File.join(root, "host_vars", "localhost.yml"), "vars_plugin_file_var: file\n")
    File.write(File.join(root, "inv.ini"), <<-INI)
      [all]
      localhost ansible_connection=local
      INI
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ vars_plugin_var }}/{{ vars_plugin_file_var }}"
      YAML

    output, status = ps_run_vars(root, {"ANSIBLE_VARS_PLUGINS" => vars_dir})
    status.success?.must_equal(true)
    (output.includes?("\"msg\": \"present/file\"")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end

  it "runs a playbook-adjacent vars plugin without any env var" do
    root = PluginSpecHelper.tmp_path("configured-plugins-vars-adjacent")
    Dir.mkdir_p(File.join(root, "vars_plugins"))
    File.write(File.join(root, "vars_plugins", "adjacent.py"), <<-PYTHON)
      from ansible.plugins.vars import BaseVarsPlugin

      DOCUMENTATION = """
          name: adjacent
          short_description: playbook-adjacent vars plugin
          options: {}
      """


      class VarsModule(BaseVarsPlugin):
          REQUIRES_ENABLED = False

          def get_vars(self, loader, path, entities, cache=True):
              return {"adjacent_var": "present"}
      PYTHON
    File.write(File.join(root, "inv.ini"), <<-INI)
      [all]
      localhost ansible_connection=local
      INI
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ adjacent_var | default('UNDEF') }}"
      YAML

    output, status = ps_run_vars(root, {} of String => String)
    status.success?.must_equal(true)
    (output.includes?("\"msg\": \"present\"")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end

  it "skips a REQUIRES_ENABLED vars plugin unless ANSIBLE_VARS_ENABLED names it" do
    root = PluginSpecHelper.tmp_path("configured-plugins-vars-enabled")
    Dir.mkdir_p(File.join(root, "vars_plugins"))
    File.write(File.join(root, "vars_plugins", "optin.py"), <<-PYTHON)
      from ansible.plugins.vars import BaseVarsPlugin

      DOCUMENTATION = """
          name: optin
          short_description: opt-in vars plugin
          options: {}
      """


      class VarsModule(BaseVarsPlugin):
          REQUIRES_ENABLED = True

          def get_vars(self, loader, path, entities, cache=True):
              return {"optin_var": "present"}
      PYTHON
    File.write(File.join(root, "inv.ini"), <<-INI)
      [all]
      localhost ansible_connection=local
      INI
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ optin_var | default('UNDEF') }}"
      YAML

    skipped, skipped_status = ps_run_vars(root, {} of String => String)
    skipped_status.success?.must_equal(true)
    (skipped.includes?("\"msg\": \"UNDEF\"")).must_equal(true)

    enabled, enabled_status = ps_run_vars(root, {"ANSIBLE_VARS_ENABLED" => "optin"})
    enabled_status.success?.must_equal(true)
    (enabled.includes?("\"msg\": \"present\"")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end

  # Roles load after the inventory, so their own vars_plugins/ are never scanned
  # (see KNOWN_MISSING.md). Ansible does load them, and a role's plugin that
  # patches ansible's controller internals therefore aborts real ansible while
  # this engine runs the play - gekmihesg.openwrt (via
  # itdoginfo.domain_routing_openwrt) does exactly that to _configure_module,
  # failing real ansible at Gathering Facts with "not enough values to unpack
  # (expected 4, got 2)" (issue #1844).
  it "does not import a role's own vars_plugins/ directory" do
    root = PluginSpecHelper.tmp_path("configured-plugins-vars-role")
    role = File.join(root, "roles", "gadget")
    Dir.mkdir_p(File.join(role, "vars_plugins"))
    Dir.mkdir_p(File.join(role, "tasks"))
    File.write(File.join(role, "vars_plugins", "adjacent.py"), <<-PYTHON)
      raise RuntimeError("a role's vars plugin must never be imported")
      PYTHON
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - debug:
          msg: "{{ role_plugin_var | default('UNDEF') }}"
      YAML
    File.write(File.join(root, "inv.ini"), <<-INI)
      [all]
      localhost ansible_connection=local
      INI
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - gadget
      YAML

    output, status = ps_run_vars(root, {} of String => String)
    status.success?.must_equal(true)
    (output.includes?("\"msg\": \"UNDEF\"")).must_equal(true)
  ensure
    FileUtils.rm_r(root) if root
  end

  # issue #1908: the round behind it ran a play with gather_facts on for a host
  # whose roles include gekmihesg.openwrt, whose vars_plugins/monkeypatch.py
  # patches ansible's controller at import time and so aborts real ansible
  # during fact gathering. The same shape must leave this engine's fact
  # gathering untouched: a plugin file that is imported writes its marker, and
  # the play then reports a gathered host plus the role's guarded task skipped.
  it "gathers facts for a role shipping a vars_plugins/ file that patches ansible" do
    root = PluginSpecHelper.tmp_path("configured-plugins-vars-role-facts")
    role = File.join(root, "roles", "gadget")
    Dir.mkdir_p(File.join(role, "vars_plugins"))
    Dir.mkdir_p(File.join(role, "tasks"))
    marker = File.join(role, "vars_plugins", "imported.marker")
    File.write(File.join(role, "vars_plugins", "monkeypatch.py"), <<-PYTHON)
      import os

      with open(os.path.join(os.path.dirname(__file__), "imported.marker"), "w") as handle:
          handle.write("imported")
      PYTHON
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: pin defaults
        debug:
          msg: "{{ role_plugin_var | default('UNDEF') }}"
        when: "'gadget' in group_names"
      YAML
    File.write(File.join(root, "inv.ini"), <<-INI)
      [all]
      localhost ansible_connection=local
      INI
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        roles:
          - gadget
      YAML

    output, status = ps_run_vars(root, {} of String => String)
    status.success?.must_equal(true)
    (output.includes?("ok=1")).must_equal(true)
    (output.includes?("skipping: [localhost]")).must_equal(true)
    File.exists?(marker).must_equal(false)
  ensure
    FileUtils.rm_r(root) if root
  end
end

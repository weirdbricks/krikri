require "../minitest_helper"
require "file_utils"

# The controller-injected `invocation` echo from a role-private Python
# module on a target that HAS ansible-core installed (issue #915).
#
# Real 2.21 is immune to the target's own ansible-core: its AnsiballZ
# payload bundles the CONTROLLER's module_utils, whose _return_formatted
# injects `invocation` (module_args = the VALIDATED params, defaults
# applied) when the action layer passed `_ansible_inject_invocation`,
# and pops the key otherwise. The py_module shim mirrors that, so the
# echo must now appear on a with-core host too - previously the module
# imported the target's own basic.py there (probe passed, no shim), and
# a pre-2.21 basic.py neither knows the key nor injects anything.
#
# The dev host running the suite has ansible-core installed
# (/usr/lib/python3/dist-packages/ansible), which is exactly the
# scenario the issue describes; the assertions below would have failed
# before the always-shim change.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "role-private python module invocation echo on a with-ansible-core host" do
  it "injects the validated module_args echo when enabled and pops it when not" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    root = File.tempname("py-module-invocation-echo")
    Dir.mkdir_p(File.join(root, "roles", "echomod", "library"))
    Dir.mkdir_p(File.join(root, "roles", "echomod", "tasks"))
    Dir.mkdir_p(File.join(root, "roles", "echomod_off", "library"))
    Dir.mkdir_p(File.join(root, "roles", "echomod_off", "tasks"))

    module_src = <<-PYTHON
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={'name': {'type': 'str', 'default': 'world'}})
      module.exit_json(greeting='hello %s' % module.params['name'])
      PYTHON
    File.write(File.join(root, "roles", "echomod", "library", "echomod.py"), module_src)
    File.write(File.join(root, "roles", "echomod_off", "library", "echomod.py"), module_src)
    File.write(File.join(root, "roles", "echomod", "tasks", "main.yml"), <<-YAML)
      - echomod:
        register: r1
      - echomod:
          name: krikri
        register: r2
      - debug:
          msg: "ECHO1 {{ r1.invocation.module_args.name }}"
      - debug:
          msg: "ECHO2 {{ r2.invocation.module_args.name }}"
      YAML
    File.write(File.join(root, "pb_off.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - echomod
      YAML
    File.write(File.join(root, "roles", "echomod_off", "tasks", "main.yml"), <<-YAML)
      - echomod:
          name: krikri
        register: r3
      - debug:
          msg: "ECHO3 {{ 'invocation' in r3 }}"
      YAML
    File.write(File.join(root, "pb_off.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - echomod_off
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - echomod
      YAML

    on_captured = IO::Memory.new
    on_status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: on_captured, error: on_captured,
      chdir: root, env: {"ANSIBLE_INJECT_INVOCATION" => "1"})
    on_output = on_captured.to_s
    on_status.success?.must_equal(true, on_output)
    # The echo carries the VALIDATED params: the omitted name shows the
    # argument_spec default, the given name shows through as given.
    on_output.must_include(%("msg": "ECHO1 world"))
    on_output.must_include(%("msg": "ECHO2 krikri"))

    off_captured = IO::Memory.new
    off_status = Process.run(BINARY, ["-i", INVENTORY, "pb_off.yml"], output: off_captured, error: off_captured,
      chdir: root)
    off_output = off_captured.to_s
    off_status.success?.must_equal(true, off_output)
    # With the resolution off, the key is popped off the result before
    # the derived companions are added - the same inject-or-pop real
    # _return_formatted runs for both exits.
    off_output.must_include(%("msg": "ECHO3 False"))
  ensure
    FileUtils.rm_rf(root) if root
  end
end

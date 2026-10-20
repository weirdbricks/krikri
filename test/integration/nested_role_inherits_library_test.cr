require "../minitest_helper"
require "file_utils"

# ansible adds a role's library/ to the module path when the role is
# loaded and keeps it for the rest of the run, so a role pulled in via
# include_role: from the outer role still resolves the outer role's
# custom module (leongold.ovirt-ansible-dpdk-testing's nested
# configure_kernel role, issue #150).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "include_role'd nested role using the outer role's library/ module" do
  it "resolves the outer role's custom module from the nested role" do
    root = File.tempname("nested-role-library")
    Dir.mkdir_p(File.join(root, "roles", "outer", "library"))
    Dir.mkdir_p(File.join(root, "roles", "outer", "tasks"))
    Dir.mkdir_p(File.join(root, "roles", "outer", "roles", "inner", "tasks"))

    File.write(File.join(root, "roles", "outer", "library", "mymod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={'text': {'type': 'str', 'default': 'x'}})
      module.exit_json(changed=False, echoed=module.params['text'])
      PYTHON

    File.write(File.join(root, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: nested include
        include_role:
          name: "outer/roles/inner"
      YAML

    File.write(File.join(root, "roles", "outer", "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: use outer library from inner
        mymod:
          text: nested-marker
        register: r2
      - name: show nested
        debug:
          var: r2.echoed
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - outer
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("nested-marker", output.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

require "../minitest_helper"
require "file_utils"

# A role-private module importing the role's OWN custom
# ansible.module_utils package, end to end through the real binary.
# linux-system-roles.storage's `blivet:` shape: its library/blivet.py
# does `from ansible.module_utils.storage_lsr.argument_validator import
# validate_parameters`, where `storage_lsr` is not a ansible-core
# package but the role's own code under `<role_root>/module_utils/
# storage_lsr/`. Ansible's AnsiballZ wrapper bundles that tree into
# the zipapp alongside the module source; this engine used to upload
# only the single module source file, so the import died with a plain
# Python ModuleNotFoundError and the task hard-FAILED while real
# ansible-playbook ran it.
#
# The bundled tree travels through the same plugin-config transport as
# the module source itself (base64 rel-path -> content, staged by the
# py_module plugin under ansible/module_utils/ on the target) - no
# separate directory-upload mechanism, so local and SSH connections both
# get it for free.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "role-private module importing the role's own module_utils package" do
  it "resolves the import end to end when the role ships module_utils/" do
    root = File.tempname("py-module-utils")
    Dir.mkdir_p(File.join(root, "roles", "utilsrole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "utilsrole", "module_utils", "storage_lsr"))
    Dir.mkdir_p(File.join(root, "roles", "utilsrole", "tasks"))

    File.write(File.join(root, "roles", "utilsrole", "module_utils", "storage_lsr", "__init__.py"), "")
    File.write(File.join(root, "roles", "utilsrole", "module_utils", "storage_lsr", "argument_validator.py"), <<-PYTHON)
      def validate_parameters(value):
          return value * 2
      PYTHON

    File.write(File.join(root, "roles", "utilsrole", "library", "bundled_mod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule
      from ansible.module_utils.storage_lsr.argument_validator import validate_parameters

      module = AnsibleModule(argument_spec={'value': {'type': 'int', 'required': True}})
      module.exit_json(changed=False, doubled=validate_parameters(module.params['value']))
      PYTHON

    File.write(File.join(root, "roles", "utilsrole", "tasks", "main.yml"), <<-YAML)
      - name: run module importing the role's own module_utils package
        bundled_mod:
          value: 21
        register: mod_out
      - name: surface the module's own result field
        debug:
          msg: "{{ mod_out.doubled }}"
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - utilsrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    # doubled=42 proves the helper in the role's OWN module_utils package
    # actually executed - not just that the module didn't crash.
    output.to_s.must_include("42", output.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still runs a module from a role with NO module_utils directory, unchanged" do
    root = File.tempname("py-module-utils-negative")
    Dir.mkdir_p(File.join(root, "roles", "plainrole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "plainrole", "tasks"))

    File.write(File.join(root, "roles", "plainrole", "library", "plain_mod.py"), <<-PYTHON)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={})
      module.exit_json(changed=False, marker="plain-ok")
      PYTHON

    File.write(File.join(root, "roles", "plainrole", "tasks", "main.yml"), <<-YAML)
      - name: run module from a role without module_utils
        plain_mod: {}
        register: mod_out
      - name: surface the module's own result field
        debug:
          msg: "{{ mod_out.marker }}"
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - plainrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("plain-ok", output.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

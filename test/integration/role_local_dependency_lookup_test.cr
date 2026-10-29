require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_action_runner"

# A meta dependency role's lookup_plugins/ is on the plugin search path
# for the depending role's own tasks (ansible's add_all_plugin_dirs at
# Role.load): gzm55.local_ssh_known_hosts depends on
# gzm55.local_id_plugin, which ships lookup_plugins/id.py, and the
# main role's task resolves `{{ lookup('id', 'uname') }}` to the
# current user's name (issue #519). Before this, the lookup fell
# through to "undefined" and a later user-owning task failed with
# "failed to look up user undefined". Modeled on
# role_local_action_plugin_context_test.cr: the fixture's `id`
# equivalent returns ['bob'], so the lookup - which takes the first
# list element - reads 'bob' in the debug output. On a controller
# whose python3 cannot import the `ansible` package the whole lookup
# mechanism is unavailable and the template keeps its degraded shape,
# so the meaningful assertions only run when it is importable (same
# suite-green-either-way convention as the lookup runner unit specs).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def ansible_importable : Bool
  python = Krikri::PythonActionRunner.python_executable
  return false unless python
  status = Process.run(python, ["-c", "from ansible.plugins.lookup import LookupBase"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  status.success?
end

describe "meta dependency role's lookup_plugins serving the depending role (role_local_dependency_lookup_test.cr)" do
  it "resolves lookup('id', 'uname') through the dependency role's lookup plugin" do
    return unless ansible_importable

    root = File.tempname("role-local-dependency-lookup")
    Dir.mkdir_p(File.join(root, "roles", "mainrole", "meta"))
    Dir.mkdir_p(File.join(root, "roles", "mainrole", "tasks"))
    Dir.mkdir_p(File.join(root, "roles", "localid", "lookup_plugins"))

    File.write(File.join(root, "roles", "localid", "lookup_plugins", "id.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase


      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return ['bob']
      PYTHON

    File.write(File.join(root, "roles", "mainrole", "meta", "main.yml"), <<-YAML)
      dependencies:
        - role: localid
      YAML

    File.write(File.join(root, "roles", "mainrole", "tasks", "main.yml"), <<-YAML)
      - name: Resolve current user
        debug:
          msg: "{{ lookup('id', 'uname') }}"
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - mainrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("\"msg\": \"bob\"", output.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

require "../minitest_helper"
require "file_utils"

# Ansible loads a role's own `test_plugins/*.py` (Python files exposing a
# TestModule class whose tests() method returns a {test_name: callable}
# dict) on the CONTROLLER the same way it loads role-private
# `filter_plugins/*.py` - krikri had no equivalent for test plugins at all
# before this, so any task or template referencing one hard-failed with
# "No test named 'X'." / "unknown test \"X\"" where Ansible resolved and
# ran it. Found via Aisbergg.networkmanager's own `list` test (round
# 2300110): its templates/NetworkManager.conf.j2 uses `value is list`,
# which jinja2/ansible-core does NOT provide as a builtin test, so the
# role ships test_plugins/list.py - krikri failed the render with
# `Failed to render template: line 4: unknown test "list"` where
# ansible-playbook passed. See PythonTestRunner for the mechanism
# (delegates to the controller's own python3; every failure degrades to
# the plain unknown-test error, so roles WITHOUT custom test plugins -
# the overwhelming majority - are unaffected).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def write_role_with_test(root : String) : Nil
  Dir.mkdir_p(File.join(root, "roles", "myrole", "test_plugins"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "templates"))
  File.write(File.join(root, "roles", "myrole", "test_plugins", "list.py"), <<-PYTHON)
    from types import GeneratorType


    class TestModule(object):
        def tests(self):
            return {"list": self.is_list}

        def is_list(self, value):
            return isinstance(value, (list, GeneratorType))
    PYTHON
  File.write(File.join(root, "roles", "myrole", "templates", "out.conf.j2"), <<-J2)
    {% macro render_section(values) %}
    {%   for key, value in values|dictsort() %}
    {%     if value is list %}
    {{ key }} = {{ value | join(', ') }}
    {%     else %}
    {{ key }} = {{ value }}
    {%     endif %}
    {%   endfor %}
    {% endmacro %}
    {% for section, options in cfg | dictsort() %}
    [{{ section }}]
    {{ render_section(options) }}
    {% endfor %}
    J2
end

private def run_playbook(root : String, playbook_body : String) : {Process::Status, String}
  File.write(File.join(root, "pb.yml"), playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
end

describe "role-local test_plugins/*.py custom tests" do
  it "resolves a custom test in a real .j2 template (the Aisbergg.networkmanager shape)" do
    root = File.tempname("test-plugins-template")
    write_role_with_test(root)
    dest = File.join(root, "out.conf")
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: render template using custom test
        ansible.builtin.template:
          src: out.conf.j2
          dest: #{dest}
        vars:
          cfg:
            main:
              dns: none
              autoconnect-slaves: 1
              ipv6.method: disabled
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.must_equal(true, output)
    output.wont_include("unknown test", output)
    output.wont_include("No test named", output)
    File.read(dest).must_include("[main]", output)
    File.read(dest).must_include("autoconnect-slaves = 1\n", output)
    File.read(dest).must_include("dns = none\n", output)
    File.read(dest).must_include("ipv6.method = disabled\n", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a custom test in the {{ }} expression path ({{ x is list }})" do
    root = File.tempname("test-plugins-expression")
    write_role_with_test(root)
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: list value is a list
        ansible.builtin.set_fact:
          is_list: "{{ mylist is list }}"
      - name: string value is not a list
        ansible.builtin.set_fact:
          not_list: "{{ mystring is list }}"
      - name: show results
        ansible.builtin.debug:
          msg: "{{ is_list }} / {{ not_list }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist: [1, 2]
          mystring: hello
        roles:
          - myrole
      YAML

    status.success?.must_equal(true, output)
    output.must_include("True / False", output)
    output.wont_include("No test named", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a custom test in a when: condition (ConditionalEvaluator's compile-time test-name pre-pass)" do
    root = File.tempname("test-plugins-when")
    write_role_with_test(root)
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: gated on custom test
        ansible.builtin.debug:
          msg: "when path worked"
        when: "mylist is list"
        vars:
          mylist: [1, 2]
      - name: short-circuited custom test must not hard-fail the pre-pass
        ansible.builtin.debug:
          msg: "short circuit worked"
        when: "false and mylist is list"
        vars:
          mylist: [1, 2]
      YAML
    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.must_equal(true, output)
    output.must_include("when path worked", output)
    # `false and mylist is list` is simply False - the task skips, exactly
    # as Ansible skips it; the assertion is that the compile-time pre-pass
    # accepted the role-local test name instead of hard-failing.
    output.must_include("short-circuited custom test", output)
    output.wont_include("No test named", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still hard-fails a test no plugin defines" do
    root = File.tempname("test-plugins-unknown")
    write_role_with_test(root)
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: unknown test must fail
        ansible.builtin.debug:
          msg: "{{ mylist is totally_bogus_test_xyz }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist: [1, 2]
        roles:
          - myrole
      YAML

    status.success?.must_equal(false, output)
    output.must_include("No test named 'totally_bogus_test_xyz'", output)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

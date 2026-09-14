require "../spec_helper"
require "file_utils"

# Role-local custom `lookup_plugins/*.py` support - real Ansible loads a
# role's own lookup_plugins/ directory on the CONTROLLER (a lookup
# plugin's name IS its file name) and runs its LookupModule's
# `run(terms, variables, **kwargs)`. Before this, any lookup()/query()
# through such a name silently degraded to "undefined"/[] - which
# collapses a `loop: "{{ query(...) }}"` to ZERO iterations where real
# ansible-playbook executes once per result. Found via manala.environment
# and manala.accounts. See PythonLookupRunner for the mechanism.
#
# The dispatch specs here require the controller python3 to import the
# real `ansible` package; on a controller without it every dispatch
# degrades to the previous undefined/[] behavior instead (asserted in
# the last spec, which passes either way).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def write_role_with_lookup(root : String) : Nil
  Dir.mkdir_p(File.join(root, "roles", "myrole", "lookup_plugins"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
  File.write(File.join(root, "roles", "myrole", "lookup_plugins", "mylookup.py"), <<-PYTHON)
    from ansible.plugins.lookup import LookupBase

    class LookupModule(LookupBase):
        def run(self, terms, variables=None, **kwargs):
            prefix = kwargs.get('prefix', '')
            return [prefix + str(t) for t in self._flatten(terms)]
    PYTHON
end

private def run_playbook(root : String, playbook_body : String) : {Process::Status, String}
  File.write(File.join(root, "pb.yml"), playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
end

describe "role-local lookup_plugins/*.py custom lookups" do
  it "resolves query() with kwargs in the hand-rolled {{ }} evaluator" do
    root = File.tempname("lookup-plugins-hand-rolled")
    write_role_with_lookup(root)
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: use custom lookup
        ansible.builtin.set_fact:
          result: "{{ query('mylookup', ['a', 'b', 'c'], prefix='x-') }}"
      - ansible.builtin.debug:
          var: result
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_true, output
    output.should contain("x-a"), output
    output.should contain("x-c"), output
  end

  it "resolves query() inside a real Jinja for-loop block (the {{ }}-path's Crinja renderer)" do
    root = File.tempname("lookup-plugins-crinja-block")
    write_role_with_lookup(root)
    dest = File.join(root, "out.txt")
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: render custom lookup through block tags
        ansible.builtin.copy:
          dest: #{dest}
          content: |
            {% for item in query('mylookup', ['p','q'], prefix='y-') %}
            GOT: {{ item }}
            {% endfor %}
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_true, output
    body = File.read(dest)
    body.should contain("GOT: y-p"), body
    body.should contain("GOT: y-q"), body
    body.should_not contain("{%"), body
  end

  it "resolves lookup() in a real .j2 template file (the template action's own fresh Crinja environment)" do
    root = File.tempname("lookup-plugins-crinja-template")
    write_role_with_lookup(root)
    Dir.mkdir_p(File.join(root, "roles", "myrole", "templates"))
    dest = File.join(root, "out.conf")
    File.write(File.join(root, "roles", "myrole", "templates", "out.conf.j2"), <<-J2)
      {% for item in query('mylookup', ['m','n']) %}
      line: {{ item }}
      {% endfor %}
      J2
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: render template using custom lookup
        ansible.builtin.template:
          src: out.conf.j2
          dest: #{dest}
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_true, output
    body = File.read(dest)
    body.should contain("line: m"), body
    body.should contain("line: n"), body
  end

  it "surfaces the plugin's own failure as a real task failure" do
    root = File.tempname("lookup-plugins-failure")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "lookup_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "lookup_plugins", "boom.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase
      from ansible.errors import AnsibleError

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              raise AnsibleError('exploding on purpose')
      PYTHON
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: use a lookup that raises internally
        ansible.builtin.set_fact:
          boom: "{{ query('boom', ['x']) }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_false, output
    output.should contain("custom lookup 'boom' failed"), output
    output.should contain("exploding on purpose"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "degrades an unknown lookup name to the previous undefined/[] behavior" do
    root = File.tempname("lookup-plugins-none")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: unknown custom lookup, no lookup_plugins/ at all
        ansible.builtin.set_fact:
          missing: "{{ query('no_such_lookup_xyz', ['a']) }}"
      - ansible.builtin.debug:
          var: missing
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    # Same shape as before the custom-lookup support existed: query()
    # collapses the unknown lookup to an empty list, the run proceeds.
    status.success?.should be_true, output
    output.should contain("missing: []"), output
  ensure
    FileUtils.rm_rf(root) if root
  end
end

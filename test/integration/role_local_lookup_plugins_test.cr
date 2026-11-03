require "../minitest_helper"
require "file_utils"

# Role-local custom `lookup_plugins/*.py` support - Ansible loads a
# role's own lookup_plugins/ directory on the CONTROLLER (a lookup
# plugin's name IS its file name) and runs its LookupModule's
# `run(terms, variables, **kwargs)`. Before this, any lookup()/query()
# through such a name silently degraded to "undefined"/[] - which
# collapses a `loop: "{{ query(...) }}"` to ZERO iterations where
# ansible-playbook executes once per result. Found via manala.environment
# and manala.accounts. See PythonLookupRunner for the mechanism.
#
# The dispatch specs here require the controller python3 to import the
# `Ansible` package; on a controller without it every dispatch
# degrades to the previous undefined/[] behavior instead (asserted in
# the last spec, which passes either way).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

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

private def run_playbook(root : String, playbook_body : String,
                         env : Hash(String, String)? = nil) : {Process::Status, String}
  File.write(File.join(root, "pb.yml"), playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"],
    output: output, error: output, chdir: root, env: env)
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

    status.success?.must_equal(true, output)
    output.must_include("x-a", output)
    output.must_include("x-c", output)
  end

  it "resolves query() inside a Jinja for-loop block (the {{ }}-path's Crinja renderer)" do
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

    status.success?.must_equal(true, output)
    body = File.read(dest)
    body.must_include("GOT: y-p", body)
    body.must_include("GOT: y-q", body)
    body.wont_include("{%", body)
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

    status.success?.must_equal(true, output)
    body = File.read(dest)
    body.must_include("line: m", body)
    body.must_include("line: n", body)
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

    status.success?.must_equal(false, output)
    output.must_include("custom lookup 'boom' failed", output)
    output.must_include("exploding on purpose", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "words an import failure while loading the plugin as 'failed to load'" do
    root = File.tempname("lookup-plugins-load-failure")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "lookup_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "lookup_plugins", "badimport.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase
      import krikri_no_such_module

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return []
      PYTHON
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: use a lookup whose file cannot import
        ansible.builtin.set_fact:
          x: "{{ query('badimport', ['x']) }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.must_equal(false, output)
    output.must_include("The lookup plugin 'badimport' failed to load: No module named 'krikri_no_such_module'", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails an unknown lookup name like ansible instead of a silent empty list (issue #751)" do
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

    # Originally pinned the pre-custom-lookup-support degradation (query()
    # collapsing the unknown lookup to an empty list, the run proceeding);
    # real ansible-core 2.19 task-fails the name that exists nowhere with
    # its own not-found message (issue #751, live-verified), so the run
    # must fail the same way.
    status.success?.must_equal(false, output)
    output.must_include("The lookup plugin 'no_such_lookup_xyz' was not found.", output)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

# Issue #778: the same custom-lookup mechanism for a `lookup_plugins/
# directory NEXT TO THE PLAYBOOK (the reproduction in the issue) rather
# than inside a role, plus the two configured search roots Ansible's own
# PluginLoader also honours: `ANSIBLE_LOOKUP_PLUGINS` and the default
# `~/.ansible/plugins/lookup`. All three were reported as "The lookup
# plugin 'X' was not found." (env/user dir) or silently null before.
private ISSUE_778_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - ansible.builtin.set_fact:
          pk: "{{ query('mylist') }}"
      - ansible.builtin.debug:
          var: pk
      - ansible.builtin.debug:
          msg: "{{ query('mylist') | length }}"
  YAML

private def write_playbook_adjacent_lookup(root : String) : Nil
  Dir.mkdir_p(File.join(root, "lookup_plugins"))
  File.write(File.join(root, "lookup_plugins", "mylist.py"), <<-PYTHON)
    from ansible.plugins.lookup import LookupBase

    class LookupModule(LookupBase):
        def run(self, terms, variables=None, **kwargs):
            return ["alpha", "beta"]
    PYTHON
end

describe "playbook-adjacent lookup_plugins/*.py custom lookups (issue #778)" do
  it "resolves the issue's own query()/set_fact/debug repro" do
    root = File.tempname("lookup-plugins-playbook-adjacent")
    write_playbook_adjacent_lookup(root)
    status, output = run_playbook(root, ISSUE_778_PLAYBOOK)

    status.success?.must_equal(true, output)
    output.must_include("\"alpha\"", output)
    output.must_include("\"beta\"", output)
    output.must_include("\"msg\": 2", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a plugin from a directory named by ANSIBLE_LOOKUP_PLUGINS" do
    root = File.tempname("lookup-plugins-env-root")
    plugin_dir = File.join(root, "elsewhere", "lookups")
    Dir.mkdir_p(plugin_dir)
    File.write(File.join(plugin_dir, "mylist.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return ["gamma"]
      PYTHON

    status, output = run_playbook(root, ISSUE_778_PLAYBOOK,
      {"ANSIBLE_LOOKUP_PLUGINS" => plugin_dir})
    status.success?.must_equal(true, output)
    output.must_include("\"gamma\"", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a plugin from the default ~/.ansible/plugins/lookup directory" do
    root = File.tempname("lookup-plugins-user-dir")
    home = File.join(root, "home")
    Dir.mkdir_p(File.join(home, ".ansible", "plugins", "lookup"))
    File.write(File.join(home, ".ansible", "plugins", "lookup", "mylist.py"), <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return ["delta"]
      PYTHON

    status, output = run_playbook(root, ISSUE_778_PLAYBOOK, {"HOME" => home})
    status.success?.must_equal(true, output)
    output.must_include("\"delta\"", output)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

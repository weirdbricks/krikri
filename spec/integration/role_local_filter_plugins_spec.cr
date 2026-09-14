require "../spec_helper"
require "file_utils"

# Real Ansible loads a role's own `filter_plugins/*.py` (Python files
# exposing a FilterModule class whose filters() method returns a
# {filter_name: callable} dict) on the CONTROLLER the same way it loads
# role-private `library/*.py` modules - krikri had no equivalent for
# filters at all before this, so any task referencing one hard-failed
# with "No filter named 'X'." where real Ansible resolved and ran it.
# Found via stackhpc.luks's own `luks_key` and MichaelRigart.interfaces's
# `bond_check`. See PythonFilterRunner for the mechanism (delegates to
# the controller's own python3; every failure degrades to the plain
# unknown-filter error, so roles WITHOUT custom filter plugins - the
# overwhelming majority - are unaffected).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def write_role_with_filter(root : String) : Nil
  Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "templates"))
  File.write(File.join(root, "roles", "myrole", "filter_plugins", "myfilters.py"), <<-PYTHON)
    class FilterModule(object):
        def filters(self):
            return {"double": self.double}

        def double(self, x):
            return x * 2
    PYTHON
  File.write(File.join(root, "roles", "myrole", "templates", "out.conf.j2"), <<-J2)
    value={{ 10 | double }}
    J2
end

private def run_playbook(root : String, playbook_body : String) : {Process::Status, String}
  File.write(File.join(root, "pb.yml"), playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
end

describe "role-local filter_plugins/*.py custom filters" do
  it "resolves a custom filter in the hand-rolled {{ }} evaluator (FilterEngine)" do
    root = File.tempname("filter-plugins-hand-rolled")
    write_role_with_filter(root)
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: use custom filter
        ansible.builtin.debug:
          msg: "{{ 21 | double }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_true, output
    output.should contain("42"), output
    output.should_not contain("No filter named"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a custom filter in a real .j2 template (vendored-Crinja path, separate environment from the {{ }} path)" do
    root = File.tempname("filter-plugins-crinja")
    write_role_with_filter(root)
    dest = File.join(root, "out.conf")
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: render template using custom filter
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
    output.should_not contain("No filter named"), output
    File.read(dest).should eq("value=20\n")
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a custom filter used inside a when: condition (ConditionalEvaluator's compile-time filter-name pre-pass)" do
    root = File.tempname("filter-plugins-when")
    write_role_with_filter(root)
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: gated on custom filter
        ansible.builtin.debug:
          msg: "when path worked"
        when: "(5 | double) == 10"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_true, output
    output.should contain("when path worked"), output
    output.should_not contain("No filter named"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "surfaces the filter's own failure instead of a misleading 'No filter named' error (round 83177)" do
    root = File.tempname("filter-plugins-internal-failure")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "filter_plugins", "myfilters.py"), <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"xrt_latest": self.xrt_latest}

          def xrt_latest(self, x):
              raise ValueError("No XRT version found for this OS")
      PYTHON
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: use a filter that raises internally
        ansible.builtin.debug:
          msg: "{{ 'aws' | xrt_latest }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_false, output
    output.should contain("The filter plugin 'xrt_latest' failed"), output
    output.should contain("No XRT version found for this OS"), output
    output.should_not contain("No filter named"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a custom filter behind a leading parenthesized sub-expression with attribute access (round: diodonfrost.vagrant)" do
    # Real role shape: `{{ (vagrant_index.content | from_json).versions |
    # list | sort_versions | last }}` with the role's own
    # filter_plugins/sort_versions.py. The leading-paren construct is
    # evaluated by ExpressionEvaluator's Crinja-first delegation
    # (render_via_crinja_value -> CrinjaRenderer#evaluate_value!), which
    # raises Crinja's unknown-feature error for the custom filter mid-
    # evaluation - so the case needs the register-and-retry gate on the
    # raw-value entry point, not just #render's rescue. All three
    # spellings are asserted together: the builtin-only chain, the
    # custom filter without the paren (both already worked), and the
    # custom filter behind the paren (the divergence - krikri rendered
    # the literal string "undefined" into a download URL while real
    # ansible-playbook resolved the latest version).
    root = File.tempname("filter-plugins-paren-attr")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "filter_plugins", "sort_versions.py"), <<-'PYTHON')
      import re
      def _version_key(version_string):
          return [int(x) for x in re.findall(r'\d+', version_string)]
      def filter_sort_versions(value):
          return sorted(value, key=_version_key)
      class FilterModule(object):
          def filters(self):
              return {'sort_versions': filter_sort_versions}
      PYTHON
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: builtin sort behind leading paren (must keep working)
        ansible.builtin.set_fact:
          a1: "{{ (vagrant_index.content | from_json).versions | list | sort | last }}"
        vars:
          vagrant_index:
            content: '{"versions": {"2.4.1": {}, "2.4.3": {}, "2.3.0": {}}}'
      - name: custom filter without leading paren (must keep working)
        ansible.builtin.set_fact:
          a2: "{{ ['2.4.1', '2.4.3', '2.3.0'] | sort_versions | last }}"
      - name: custom filter behind leading paren (the bug)
        ansible.builtin.set_fact:
          a3: "{{ (vagrant_index.content | from_json).versions | list | sort_versions | last }}"
        vars:
          vagrant_index:
            content: '{"versions": {"2.4.1": {}, "2.4.3": {}, "2.3.0": {}}}'
      - name: surface all three results
        ansible.builtin.debug:
          msg: "{{ a1 }} / {{ a2 }} / {{ a3 }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_true, output
    output.should contain("2.4.3 / 2.4.3 / 2.4.3"), output
    output.should_not contain("undefined"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still hard-fails a genuinely unknown filter behind a leading paren instead of degrading to 'undefined'" do
    # The other half of the paren-path gate: with no filter_plugins
    # source defining the name, the expression must fail the task with
    # real Ansible's wording - not silently collapse to the
    # "undefined" sentinel the fallback path used to produce.
    root = File.tempname("filter-plugins-paren-unknown")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: unknown filter behind leading paren
        ansible.builtin.set_fact:
          a: "{{ (vagrant_index.content | from_json).versions | list | totally_bogus_filter_xyz | last }}"
        vars:
          vagrant_index:
            content: '{"versions": {"2.4.1": {}, "2.4.3": {}, "2.3.0": {}}}'
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_false, output
    output.should contain("No filter named 'totally_bogus_filter_xyz'"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still raises the plain unknown-filter error when no filter_plugins source defines the name" do
    root = File.tempname("filter-plugins-none")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: unknown filter, no filter_plugins/ at all
        ansible.builtin.debug:
          msg: "{{ 21 | totally_bogus_filter_xyz }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.should be_false, output
    output.should contain("No filter named 'totally_bogus_filter_xyz'"), output
  ensure
    FileUtils.rm_rf(root) if root
  end
end

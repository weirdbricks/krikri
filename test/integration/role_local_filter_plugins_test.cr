require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_filter_runner"

# Ansible loads a role's own `filter_plugins/*.py` (Python files
# exposing a FilterModule class whose filters() method returns a
# {filter_name: callable} dict) on the CONTROLLER the same way it loads
# role-private `library/*.py` modules - krikri had no equivalent for
# filters at all before this, so any task referencing one hard-failed
# with "No filter named 'X'." where Ansible resolved and ran it.
# Found via stackhpc.luks's own `luks_key` and MichaelRigart.interfaces's
# `bond_check`. See PythonFilterRunner for the mechanism (delegates to
# the controller's own python3; every failure degrades to the plain
# unknown-filter error, so roles WITHOUT custom filter plugins - the
# overwhelming majority - are unaffected).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

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

    status.success?.must_equal(true, output)
    output.must_include("42", output)
    output.wont_include("No filter named", output)
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

    status.success?.must_equal(true, output)
    output.wont_include("No filter named", output)
    # The <<- heredoc written to out.conf.j2 has no final newline, and
    # Ansible writes only the trailing newlines the template source had.
    File.read(dest).must_equal("value=20")
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

    status.success?.must_equal(true, output)
    output.must_include("when path worked", output)
    output.wont_include("No filter named", output)
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

    status.success?.must_equal(false, output)
    output.must_include("The filter plugin 'xrt_latest' failed", output)
    output.must_include("No XRT version found for this OS", output)
    output.wont_include("No filter named", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "resolves a custom filter behind a leading parenthesized sub-expression with attribute access (round: diodonfrost.vagrant)" do
    # Real role shape: `{{ (vagrant_index.content | from_json).versions |
    # list | sort_versions | last }}` with the role's own
    # filter_plugins/sort_versions.py. The leading-paren construct is
    # evaluated by ExpressionEvaluator's Crinja-first delegation
    # (render_via_jinja_value -> JinjaRenderer#evaluate_value!), which
    # raises Crinja's unknown-feature error for the custom filter mid-
    # evaluation - so the case needs the register-and-retry gate on the
    # raw-value entry point, not just #render's rescue. All three
    # spellings are asserted together: the builtin-only chain, the
    # custom filter without the paren (both already worked), and the
    # custom filter behind the paren (the divergence - krikri rendered
    # the literal string "undefined" into a download URL while
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

    status.success?.must_equal(true, output)
    output.must_include("2.4.3 / 2.4.3 / 2.4.3", output)
    output.wont_include("undefined", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still hard-fails a genuinely unknown filter behind a leading paren instead of degrading to 'undefined'" do
    # The other half of the paren-path gate: with no filter_plugins
    # source defining the name, the expression must fail the task with
    # Ansible's wording - not silently collapse to the
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

    status.success?.must_equal(false, output)
    output.must_include("No filter named 'totally_bogus_filter_xyz'", output)
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

    status.success?.must_equal(false, output)
    output.must_include("No filter named 'totally_bogus_filter_xyz'", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "passes a context stub as the first argument to a @pass_context-decorated filter (round 952562, stackhpc.luks)" do
    # Jinja2's @pass_context makes Jinja auto-inject a Context as
    # the FIRST positional argument, ahead of the piped value - so
    # `{{ item | luks_key }}` calls `luks_key(context, item)`. krikri
    # used to call the function with just the piped value, putting the
    # value in the `context` slot and failing with "missing 1 required
    # positional argument: 'device'" (stackhpc.luks's whole
    # filter_plugins/general.py is decorated this way). The filter here
    # mirrors that role's shape: one filter ignoring the context, one
    # reading a play variable through it (its `_get_hostvar` pattern:
    # `context.get(...)`), plus a direct Python-to-Python call passing
    # the context on (its `luks_keypath` calling `luks_key(context, ..)`).
    root = File.tempname("filter-plugins-pass-context")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "filter_plugins", "general.py"), <<-PYTHON)
      from jinja2 import pass_context

      @pass_context
      def luks_key(context, device):
          return device["device"].replace('/', '-')[1:]

      @pass_context
      def luks_keypath(context, device):
          directory = context.get("luks_keys_path")
          return "%s/%s" % (directory, luks_key(context, device))

      class FilterModule(object):
          def filters(self):
              return {"luks_key": luks_key, "luks_keypath": luks_keypath}
      PYTHON
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: use pass_context filters
        ansible.builtin.set_fact:
          key: "{{ {'device': '/dev/sdb1'} | luks_key }}"
          path: "{{ {'device': '/dev/sdb1'} | luks_keypath }}"
        vars:
          luks_keys_path: /etc/luks/keys
      - name: surface results
        ansible.builtin.debug:
          msg: "{{ key }} / {{ path }}"
      YAML

    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status.success?.must_equal(true, output)
    output.must_include("dev-sdb1 / /etc/luks/keys/dev-sdb1", output)
    output.wont_include("No filter named", output)
    output.wont_include("missing 1 required positional argument", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "passes the context stub to a plain (non-context) filter's sibling unchanged (no cross-contamination)" do
    # Plain filters must keep receiving ONLY the piped value - the
    # context injection is per-function, keyed on the decoration, never
    # a global behavior change.
    root = File.tempname("filter-plugins-pass-context-plain")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "filter_plugins", "myfilters.py"), <<-PYTHON)
      def double(x):
          return x * 2

      class FilterModule(object):
          def filters(self):
              return {"double": double}
      PYTHON
    File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: plain filter next to pass_context support
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

    status.success?.must_equal(true, output)
    output.must_include("42", output)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

describe "role-local filter_plugins file that fails to import" do
  serial! # replaces PythonFilterRunner's process-wide warning sink

  it "warns once with Ansible's wording and still serves the good file's filters" do
    root = PluginSpecHelper.tmp_path("filter-broken-import")
    Dir.mkdir_p(File.join(root, "filter_plugins"))
    broken = File.join(root, "filter_plugins", "to_toml.py")
    good = File.join(root, "filter_plugins", "good.py")
    # issue #307's real shape (notmycloud.podman_systemd): its
    # filter_plugins/to_toml.py does `import toml`, which the
    # controller rarely has - ansible prints one "Skipping plugin"
    # warning on stderr and keeps the rest of the directory loaded,
    # while krikri swallowed the import failure silently.
    File.write(broken, <<-PYTHON)
      import toml


      class FilterModule(object):
          def filters(self):
              return {"to_toml": self.to_toml}

          def to_toml(self, value):
              return toml.dumps(value)
      PYTHON
    File.write(good, <<-PYTHON)
      class FilterModule(object):
          def filters(self):
              return {"double": lambda x: x * 2}
      PYTHON

    captured = IO::Memory.new
    previous = Krikri::PythonFilterRunner.warning_sink
    begin
      Krikri::PythonFilterRunner.warning_sink = captured
      names = Krikri::PythonFilterRunner.filter_names([broken, good])
    ensure
      Krikri::PythonFilterRunner.warning_sink = previous
    end

    names.includes?("double").must_equal(true)
    names.includes?("to_toml").must_equal(false)
    lines = captured.to_s.lines
    lines.size.must_equal(1, captured.to_s)
    # str(ModuleNotFoundError) is the bare "No module named 'toml'" -
    # the tail ansible prints, with no exception-class prefix. toml is
    # absent on every controller this suite runs on: ansible-core
    # dropped it as a dependency long ago and nothing else here
    # installs it, so the expected text is stable.
    lines.first.must_equal(
      "[WARNING]: Skipping plugin (#{File.expand_path(broken)}), cannot load: No module named 'toml'"
    )
  end

  it "prints nothing while a role's broken filter_plugins is only registered and never rendered" do
    # Following ansible-playbook's observed behaviour (issue #307's fix
    # verification): a play whose strings never carry Jinja markers
    # prints no "Skipping plugin" warning at all even after its role was
    # fully loaded, so registering the realistic broken import into the
    # loaded-role registry must print nothing - the old eager scan at
    # Role.load printed the line before PLAY even started, which real
    # Ansible does not. The substitute below is the cleanup needed now
    # that the trigger consults the registry at ANY later marker-bearing
    # render: without it the test would spam the file's warning into the
    # suite's later tests' captured sinks.
    root = PluginSpecHelper.tmp_path("filter-register-silent")
    Dir.mkdir_p(File.join(root, "filter_plugins"))
    broken = File.join(root, "filter_plugins", "to_toml.py")
    File.write(broken, <<-PYTHON)
      import toml


      class FilterModule(object):
          def filters(self):
              return {"to_toml": self.to_toml}

          def to_toml(self, value):
              return toml.dumps(value)
      PYTHON

    captured = IO::Memory.new
    previous = Krikri::PythonFilterRunner.warning_sink
    begin
      Krikri::PythonFilterRunner.warning_sink = captured
      Krikri::PythonFilterRunner.register_role_plugin_roots(root)
    ensure
      Krikri::PythonFilterRunner.warning_sink = previous
      Krikri::PythonFilterRunner.unregister_role_plugin_roots_under(root)
    end

    captured.to_s.must_equal("")
  end

  it "fires its warning exactly once at the first filter-using templating and adds nothing later" do
    # Ansible's exact placement (verified against ansible-playbook
    # 2.19.11 for issue #307): the warning lands INLINE at the first
    # templating whose template USES a filter - where the Templar builds
    # its filter set by importing every loadable-role + playbook-adjacent
    # filter_plugins/ file - and never again after. The gate below is the
    # very call the render entries make (the bridge's
    # JinjaRenderer#render!/#evaluate_value! and the hand-rolled
    # FilterEngine dispatch).
    root = PluginSpecHelper.tmp_path("filter-first-render-warning")
    Dir.mkdir_p(File.join(root, "filter_plugins"))
    broken = File.join(root, "filter_plugins", "to_toml.py")
    File.write(broken, <<-PYTHON)
      import toml


      class FilterModule(object):
          def filters(self):
              return {"to_toml": self.to_toml}

          def to_toml(self, value):
              return toml.dumps(value)
      PYTHON

    first_captured = IO::Memory.new
    later_captured = IO::Memory.new
    previous = Krikri::PythonFilterRunner.warning_sink
    begin
      Krikri::PythonFilterRunner.warning_sink = first_captured
      Krikri::PythonFilterRunner.register_role_plugin_roots(root)
      Krikri::PythonFilterRunner.scan_for_filter_expression("1 | int", nil)
      Krikri::PythonFilterRunner.warning_sink = later_captured
      Krikri::PythonFilterRunner.scan_for_filter_expression("1 | int", nil)
      # the lazy unknown-filter query a task could still make (defines_
      # filter?/filter_names) must not repeat the warning either
      Krikri::PythonFilterRunner.filter_names([broken])
    ensure
      Krikri::PythonFilterRunner.warning_sink = previous
      Krikri::PythonFilterRunner.unregister_role_plugin_roots_under(root)
    end

    first_lines = first_captured.to_s.lines
    first_lines.size.must_equal(1, first_captured.to_s)
    first_lines.first.must_equal(
      "[WARNING]: Skipping plugin (#{File.expand_path(broken)}), cannot load: No module named 'toml'"
    )
    later_captured.to_s.must_equal("")
  end

  it "stays silent for a marker-bearing templating that uses no filter ({{ 1 + 1 }} shape)" do
    # ansible-playbook 2.19.11 prints NOTHING for a play whose only
    # templated string is `{{ 1 + 1 }}` even with a broken filter_plugins
    # file in scope (issue #307's fix verification): the Templar builds
    # its filter set only when a template USES a filter - a bare
    # expression, a test-only `x is defined` or block tags never do. The
    # gate must therefore key on filter use, not on marker presence.
    root = PluginSpecHelper.tmp_path("filter-silent-no-filter-use")
    Dir.mkdir_p(File.join(root, "filter_plugins"))
    broken = File.join(root, "filter_plugins", "to_toml.py")
    File.write(broken, "import toml\n")

    captured = IO::Memory.new
    previous = Krikri::PythonFilterRunner.warning_sink
    begin
      Krikri::PythonFilterRunner.warning_sink = captured
      Krikri::PythonFilterRunner.register_role_plugin_roots(root)
      Krikri::PythonFilterRunner.scan_for_filter_expression("1 + 1", nil)
      Krikri::PythonFilterRunner.scan_for_filter_expression("nope is defined", nil)
    ensure
      Krikri::PythonFilterRunner.warning_sink = previous
      Krikri::PythonFilterRunner.unregister_role_plugin_roots_under(root)
    end

    captured.to_s.must_equal("")
  end

  it "keeps template-less and filter-less plays silent and the first filter-using one loud (binary, issue #307 shape)" do
    # End-to-end against the compiled binary, following the live-verified
    # ansible matrix (issue #307): the broken file's own filter appears
    # in NO task of any play, yet the play whose first templated task
    # uses a filter still gets the warning (and only once), while the
    # template-less play AND the filter-less `{{ 1 + 1 }}` play stay
    # silent - the previously eager-scan behaviour announced the broken
    # file (notmycloud.podman_systemd's `import toml`) before PLAY even
    # ran.
    silent_root = File.tempname("filter-e2e-silent")
    filterless_root = File.tempname("filter-e2e-filterless")
    filter_root = File.tempname("filter-e2e-first-render")
    begin
      {silent_root, filterless_root, filter_root}.each do |root|
        Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
        Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
        File.write(File.join(root, "roles", "myrole", "filter_plugins", "to_toml.py"), <<-PYTHON)
          import toml


          class FilterModule(object):
              def filters(self):
                  return {"to_toml": self.to_toml}

              def to_toml(self, value):
                  return toml.dumps(value)
          PYTHON
      end
      File.write(File.join(filter_root, "roles", "myrole", "filter_plugins", "good.py"), <<-PYTHON)
        class FilterModule(object):
            def filters(self):
                return {"double": lambda x: x * 2}
        PYTHON
      File.write(File.join(silent_root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - name: no Jinja markers anywhere
          ansible.builtin.command: echo hi
        YAML
      File.write(File.join(filterless_root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - name: marker-bearing but filter-free templating
          ansible.builtin.debug:
            msg: "{{ 1 + 1 }}"
        YAML
      File.write(File.join(filter_root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - name: the play's first filter-using templating
          ansible.builtin.debug:
            msg: "{{ 21 | double }}"
        YAML

      play = <<-YAML
        - hosts: localhost
          connection: local
          gather_facts: false
          roles:
            - myrole
        YAML

      silent_status, silent_output = run_playbook(silent_root, play)
      filterless_status, filterless_output = run_playbook(filterless_root, play)
      filter_status, filter_output = run_playbook(filter_root, play)

      silent_status.success?.must_equal(true, silent_output)
      silent_output.wont_include("Skipping plugin", silent_output)

      filterless_status.success?.must_equal(true, filterless_output)
      filterless_output.must_include("\"msg\": 2", filterless_output)
      filterless_output.wont_include("Skipping plugin", filterless_output)

      filter_status.success?.must_equal(true, filter_output)
      filter_output.must_include("42", filter_output)
      filter_output.scan("Skipping plugin").size.must_equal(
        1, filter_output
      )
    ensure
      FileUtils.rm_rf(silent_root) if silent_root
      FileUtils.rm_rf(filterless_root) if filterless_root
      FileUtils.rm_rf(filter_root) if filter_root
    end
  end
end

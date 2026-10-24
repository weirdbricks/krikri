require "../minitest_helper"

# Runs the compiled binary against real playbooks (not --check mode),
# since this bug is specifically about #when_passes? crashing the whole
# PROCESS with an unhandled exception rather than failing just the one
# task - not reachable from a unit spec without a live TaskExecutor run.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "when: evaluation raising an exception" do
  # Real bug found while auditing previously-documented-but-unfixed
  # gaps: `mounts | selectattr(...) | first` on an empty match (the
  # exact shape from robertdebock.mount_options, round140) already
  # raised correctly inside `{{ }}` module-arg templating (a clean
  # failed task, matching Ansible - fixed earlier via
  # substitute_task_params's own rescue), but the IDENTICAL expression
  # used inside a bare when: condition instead crashed the entire
  # process with an unhandled Crystal exception and stack trace -
  # #when_passes? (7 call sites: solo/looped/batched tasks and meta:)
  # had no rescue at all. ansible-playbook degrades to one clean
  # failed task ("Task failed: Error while evaluating conditional:
  # ...") and continues/exits normally.
  it "fails the task cleanly instead of crashing the whole process" do
    playbook = File.tempname("when-eval-error", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mounts: []
        tasks:
          - name: raises during when
            ansible.builtin.debug:
              msg: should not print
            when: (mounts | selectattr('mount', 'equalto', '/data') | list | first).device == 'x'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    output.to_s.wont_include("Unhandled exception")
    output.to_s.must_include("Error while evaluating conditional")
    output.to_s.must_include("failed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "honors ignore_errors: - ok+ignored, not failed, host not halted" do
    playbook = File.tempname("when-eval-error-ignored", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mounts: []
        tasks:
          - name: raises during when, ignored
            ansible.builtin.debug:
              msg: should not print
            when: (mounts | selectattr('mount', 'equalto', '/data') | list | first).device == 'x'
            ignore_errors: true
          - name: still runs
            ansible.builtin.debug:
              msg: still runs
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("still runs")
    output.to_s.must_include("...ignoring")
    output.to_s.must_include("ignored=1")
    output.to_s.must_include("failed=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Follow-up (same investigation): the crash was fixed by having
  # when_passes? raise WhenEvaluationError instead of silently
  # swallowing it, but a LOOPED task's own per-item when_passes? calls
  # (execute_task_once, execute_looped_task_batched) originally still
  # treated a raise as an ordinary skip (returning nil for that item),
  # so the aggregate recap showed skipped=1 instead of Ansible's
  # failed=1 ("One or more items failed"). Fixed by having those two
  # call sites build a real failed: true result instead of returning
  # nil, so finish_looped_task's own aggregation counts it correctly.
  it "aggregates a looped when: failure to failed=1, not skipped=1" do
    playbook = File.tempname("when-eval-error-loop", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mounts: []
        tasks:
          - name: looped, when raises
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop: [a, b]
            when: (mounts | selectattr('mount', 'equalto', '/data') | list | first).device == item
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    output.to_s.wont_include("Unhandled exception")
    output.to_s.must_include("failed: [localhost] (item=a) =>")
    output.to_s.must_include("failed: [localhost] (item=b) =>")
    output.to_s.must_include("failed=1")
    output.to_s.wont_include("skipped=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "ignore_errors: on an ordinary (non-when-related) task failure" do
  # Real bug found while fixing the when: crash above: Ansible
  # ALWAYS prints a bare "...ignoring" line right after any failed
  # task's output when ignore_errors: catches it (verified directly
  # against a ansible-playbook run) - this engine never printed it
  # for an ordinary failure, only (after the fix above landed) for the
  # narrower when:-raises-an-exception case. Fixed in
  # ResultDisplay.display_result generally, not just for when:.
  it "prints ...ignoring the same way Ansible does" do
    playbook = File.tempname("ignore-errors-normal", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: normal fail ignored
            ansible.builtin.fail:
              msg: boom
            ignore_errors: true
          - name: after
            ansible.builtin.debug:
              msg: still runs
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("...ignoring")
    output.to_s.must_include("ignored=1")
    output.to_s.must_include("failed=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # ansible-core 2.19 tracks where a conditional's tested value was
  # DEFINED and labels the non-boolean error with that position:
  #   "Conditional result (True) was derived from value of type 'str' at
  #   '<playbook>:<line>:<col>'. Conditionals must have a boolean result."
  # krikri covers the narrow bare-variable shape: `when: some_var` where
  # some_var is defined in the play's own vars: - the position comes from
  # YamlSourceMap's libyaml event pass (the same one that labels task
  # origins). Live-verified against 2.19.11.
  it "labels a non-boolean conditional error with the variable's definition position" do
    playbook = File.tempname("when-value-origin", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          bogus: undefined_var | selectattr('nope')
        tasks:
          - name: conditional fails
            ansible.builtin.debug:
              msg: never
            when: bogus
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    # vars: bogus sits on line 5, its value starting at column 12.
    output.to_s.must_include("was derived from value of type 'str' at '#{File.expand_path(playbook)}:5:12'", output.to_s)
    # The clause appears in the block AND the fatal dump.
    output.to_s.must_include(%({"msg": "Task failed: Conditional result (True) was derived from value of type 'str' at '#{File.expand_path(playbook)}:5:12'. Conditionals must have a boolean result."}), output.to_s)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Same lineage decoration for the other defining layers, each
  # live-verified against 2.19.11 (round 5210000's ktechmidas.openvpn
  # bare `when:` on a role default was the reported shape): a role
  # defaults/vars file reports the VALUE token in that file; a set_fact
  # value reports the value token in the set_fact task's own file; a
  # registered result or gathered fact has no defining site and reports
  # the when: token itself; a CLI -e value reports the option label in
  # DOUBLE quotes with no position.
  it "labels a role-default-sourced conditional value with its role-file position" do
    dir = File.tempname("when-role-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), "user: \"hello\"\n")
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: bare var conditional
        ansible.builtin.debug:
          msg: hi
        when: user
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    expected = "was derived from value of type 'str' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:1:7'"
    output.to_s.must_include(expected, output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  # ansible's data lineage follows a stored value that is itself a
  # single-variable template: a var whose value is `{{ other }}` (or
  # `{{ other | default('d') }}`) tested by a bare `when:` is labeled
  # with the innermost source value's defining position, not the
  # templated var's own line (live-verified vs 2.19.11, issue #151).
  it "labels a chained role-default conditional value with the innermost source position" do
    dir = File.tempname("when-role-chain-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      gitlab_flag: "some string"
      gitlab_cond: "{{ gitlab_flag }}"
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: chained conditional
        ansible.builtin.debug:
          msg: hi
        when: gitlab_cond
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # gitlab_flag's own value token (`gitlab_flag: "some string"`, value
    # at col 14), not gitlab_cond's line.
    expected = "was derived from value of type 'str' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:1:14'"
    output.to_s.must_include(expected, output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "labels a default-filter-chained role-default conditional value with the innermost source position" do
    dir = File.tempname("when-role-chain-default-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      gitlab_flag: "some string"
      gitlab_cond: "{{ gitlab_flag | default('d') }}"
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: chained default conditional
        ansible.builtin.debug:
          msg: hi
        when: gitlab_cond
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    expected = "was derived from value of type 'str' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:1:14'"
    output.to_s.must_include(expected, output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  # ansible's `default` filter passes a DEFINED variable's own value
  # straight through, so the conditional's tested value keeps that
  # variable's lineage: with role defaults
  # `splunk_uf_inputs_conf_template: inputs.conf.j2` behind the task's
  # `when: splunk_uf_inputs_conf_template | default(false)`, real 2.19
  # labels the error with the defaults file's value position, NOT the
  # when: token's (issue #251, live-verified).
  it "labels a `var | default(false)` when: error with the variable's role-defaults position" do
    dir = File.tempname("when-default-passthrough-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      splunk_uf_inputs_conf_template: inputs.conf.j2
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: default passthrough conditional
        ansible.builtin.debug:
          msg: never runs
        when: splunk_uf_inputs_conf_template | default(false)
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # Value token `inputs.conf.j2` starts at column 33 - the same column
    # as issue #251's real-world label (defaults/main.yml:21:33).
    expected = "was derived from value of type 'str' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:1:33'"
    output.to_s.must_include(expected, output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  # The `lst | d([], true)` shape's fallback is a fresh value with no
  # lineage of its own, and real keeps labeling it at the when: value
  # token - the defined-string pass-through relabeling must not catch it.
  it "keeps labeling a fresh `d([], true)` fallback value at the when: token" do
    dir = File.tempname("when-default-fresh-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      splunk_uf_list: []
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: fresh fallback conditional
        ansible.builtin.debug:
          msg: never runs
        when: splunk_uf_list | d([], true)
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # when: sits on line 4 at column 9 (the task keyword's own value
    # token), the pre-fix compound-shape behavior.
    expected = "was derived from value of type 'list' at '#{File.join(dir, "roles", "testrole", "tasks", "main.yml")}:4:9'"
    output.to_s.must_include(expected, output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  # Same decoration must survive an include_tasks: hop inside the role:
  # the included file's tasks are parsed outside the role, so without the
  # origins travelling with the values they describe the location silently
  # disappears from the failure (live-verified vs 2.19.11: a task reached
  # via include_tasks: still reports "at '<role>/defaults/main.yml:...'".
  it "labels a role-default-sourced conditional value reached via include_tasks with its role-file position" do
    dir = File.tempname("when-role-include-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), "some_var: {}\n")
    File.write(File.join(dir, "roles", "testrole", "tasks", "sub.yml"), <<-YAML)
      - name: dict conditional
        ansible.builtin.debug:
          msg: hi
        when: some_var
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: include sub
        ansible.builtin.include_tasks: sub.yml
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    expected = "was derived from value of type 'dict' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:1:11'"
    output.to_s.must_include(expected, output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "labels a set_fact-sourced conditional value with the set_fact value's position" do
    playbook = File.tempname("when-setfact-origin", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.set_fact:
              sfv: notbool
          - name: set_fact conditional
            ansible.builtin.debug:
              msg: hi
            when: sfv
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # The value token's position (`sfv: notbool`, value at col 14) -
    # live-verified against 2.19.11 on the identical file.
    output.to_s.must_include("was derived from value of type 'str' at '#{File.expand_path(playbook)}:6:14'", output.to_s)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "labels a registered-result conditional value with the when: token position" do
    playbook = File.tempname("when-registered-origin", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: make reg
            ansible.builtin.command: "true"
            register: regout
          - name: reg conditional
            ansible.builtin.debug:
              msg: hi
            when: regout
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # A registered result has no defining site; real reports the when:
    # token itself (`when: regout`, col 13), type 'dict' - live-verified
    # against 2.19.11 on the identical file.
    output.to_s.must_include("was derived from value of type 'dict' at '#{File.expand_path(playbook)}:11:13'", output.to_s)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "labels a CLI -e conditional value with the option label" do
    playbook = File.tempname("when-ivar-origin", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: -e conditional
            ansible.builtin.debug:
              msg: hi
            when: ev
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "-e", "ev=notbool", playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include(%(was derived from value of type 'str' at "<CLI option '-e'>".), output.to_s)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Issue #21: a compound when: whose result is an int (`x is defined
  # and x|length` on a non-empty list - the java_pre_packages shape
  # from tschifftner.java) gets the same ` at '...'` clause, labelled
  # with the when: value token's position - the same position as the
  # second Origin: block (as captured from ansible-core 2.19.11).
  it "labels a compound int conditional with the when: token position" do
    playbook = File.tempname("when-compound-int-origin", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          java_pre_packages: [foo]
        tasks:
          - name: compound int conditional
            ansible.builtin.debug:
              msg: hi
            when: java_pre_packages is defined and java_pre_packages|length
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    # The when: value token sits on line 10, column 13 (`      when: `).
    output.to_s.must_include("was derived from value of type 'int' at '#{File.expand_path(playbook)}:10:13'", output.to_s)
    output.to_s.must_include(%({"msg": "Task failed: Conditional result (True) was derived from value of type 'int' at '#{File.expand_path(playbook)}:10:13'. Conditionals must have a boolean result."}), output.to_s)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Issue #325: an import_tasks:'s when: is merged ahead of each imported
  # task's own when: as TWO SEPARATE strict conditionals (playbook_parser
  # keeps them in when_condition_list), so a non-boolean failure belongs to
  # ONE clause and real's lineage points at THAT clause's tested value's
  # defining site - with the import when-gated on a truthy comparison and
  # the child task failing on a bare `when: packages_accept` (an empty
  # role-default list), real 2.19 labels
  # "<role>/defaults/main.yml:3:18" (the variable's defining site), while
  # the joined "(import) and (own)" raw string fell into the compound
  # branch and mislabeled the child task's own when: token.
  it "labels an import-gated child when: failure with the child's variable's role-default position" do
    dir = File.tempname("when-import-clause-origin", ".d")
    Dir.mkdir(dir)
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      packages_main: []
      packages_accept: []
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "apt.yml"), <<-YAML)
      - name: apt install
        ansible.builtin.debug:
          msg: never runs
        when: packages_accept
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: import apt
        ansible.builtin.import_tasks: apt.yml
        when: true_var == "x"
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          true_var: x
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    # The `[]` value token of line 2's `packages_accept:` starts at
    # column 18 - the variable's defining site in real's lineage (issue
    # #325's defaults/main.yml:3:18 shape).
    expected = "was derived from value of type 'list' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:2:18'"
    output.to_s.must_include(expected, output.to_s)
    output.to_s.must_include(%({"msg": "Task failed: Conditional result (False) was derived from value of type 'list' at '#{File.join(dir, "roles", "testrole", "defaults", "main.yml")}:2:18'. Conditionals must have a boolean result."}), output.to_s)
    # The child task's own when: value token (line 4, column 9) is the
    # pre-fix mislabel - it must not come back under a different clause
    # ordering.
    output.to_s.wont_include("was derived from value of type 'list' at '#{File.join(dir, "roles", "testrole", "tasks", "apt.yml")}:4:9'", output.to_s)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end

require "../minitest_helper"
require "file_utils"

# Regression spec for issue #143: a templated task-level become: that
# renders to a non-boolean string (a username) was read as a condition by
# ConditionalEvaluator, so the task ran as if become were on or off. Real
# ansible-core converts the rendered value with boolean() and fails the
# task with "could not be converted to 'bool'".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a templated become: that renders to a non-boolean fails the task" do
  it "fails the task with ansible's conversion error instead of running it" do
    root = File.tempname("become-non-boolean")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: configuration data
            become: "{{ user_name }}"
            debug:
              msg: hi
        vars:
          user_name: labros
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'labros' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("msg\": \"hi\"").must_equal(false, output_text)
    # Real's keyword failure is NOT an action-plugin failure: its brief
    # carries no "Action failed:" segment, and the [ERROR] block is the
    # full three-link chain ("Task failed." / the keyword / the
    # conversion message), each link Origin'd separately.
    output_text.includes?("Action failed:").must_equal(false, output_text)
    output_text.includes?("<<< caused by >>>").must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'become'.").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails a become: on ansible_user_id after Gathering Facts has run" do
    root = File.tempname("become-non-boolean-facts")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: configuration data
            become: "{{ ansible_user_id }}"
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    # Real runs Gathering Facts first (ok: [localhost]), so ansible_user_id
    # is a gathered fact by the time the become: keyword renders.
    output_text.includes?("Gathering Facts").must_equal(true, output_text)
    output_text.includes?("The value '#{`id -un`.strip}' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("ok=1").must_equal(true, output_text)
    output_text.includes?("failed=1").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #465: ansible post-validates the become keyword before it
  # finalizes the task args, so a non-bool become: reports its own
  # conversion error even when an arg is also undefined - arg templating
  # used to win with the wrong "Finalization of task args" failure.
  it "reports the become conversion error when an arg is undefined too" do
    root = File.tempname("become-non-boolean-undefined-arg")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          user_name: labros
        tasks:
          - name: configuration data
            become: "{{ user_name }}"
            command: echo {{ undefined_thing }}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'labros' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("Finalization of task args").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #881 (danbohea.platformsh-setup): real 2.19 follows the rendered
  # value's data lineage, so the conversion link of the keyword-failure
  # chain is Origin'd at where the variable was DEFINED, not at the
  # become: value token.
  it "labels the conversion link with the role default's definition position" do
    root = File.tempname("become-bool-lineage-defaults")
    Dir.mkdir_p(File.join(root, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(root, "roles", "testrole", "tasks"))
    File.write(File.join(root, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      cli_user: vagrant
      YAML
    File.write(File.join(root, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Try it
        become: "{{ cli_user }}"
        debug:
          msg: hi
      YAML
    playbook = File.join(root, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    # `cli_user: vagrant` - the value token starts at column 11, matching
    # the live repro's defaults/main.yml:31:18 shape.
    output_text.includes?("Origin: #{File.join(root, "roles", "testrole", "defaults", "main.yml")}:1:11").must_equal(true, output_text)
    # The middle keyword link still points at the become: value itself.
    output_text.includes?("Origin: #{File.join(root, "roles", "testrole", "tasks", "main.yml")}:3:11").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # The lineage follows a stored value that is itself a single-variable
  # template to its innermost source (live-verified vs 2.19.11).
  it "follows a chained single-variable template to the innermost definition" do
    root = File.tempname("become-bool-lineage-chain")
    Dir.mkdir_p(File.join(root, "roles", "testrole", "defaults"))
    Dir.mkdir_p(File.join(root, "roles", "testrole", "tasks"))
    File.write(File.join(root, "roles", "testrole", "defaults", "main.yml"), <<-YAML)
      inner: vagrant
      outer: "{{ inner }}"
      YAML
    File.write(File.join(root, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Try it
        become: "{{ outer }}"
        debug:
          msg: hi
      YAML
    playbook = File.join(root, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("Origin: #{File.join(root, "roles", "testrole", "defaults", "main.yml")}:1:8").must_equal(true, output_text)
    output_text.includes?("Origin: #{File.join(root, "roles", "testrole", "defaults", "main.yml")}:2:8").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # A value the expression DERIVED has no lineage of its own: real keeps
  # labeling the conversion link at the keyword value token (live-verified
  # vs 2.19.11), so the lineage scan must not catch derived shapes.
  it "keeps the keyword value's own origin for a derived expression" do
    root = File.tempname("become-bool-lineage-derived")
    Dir.mkdir(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          user_name: labros
        tasks:
          - name: configuration data
            become: "{{ user_name | upper }}"
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'LABROS' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:5:16").must_equal(false, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:8:15").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #1497: a LITERAL play-level become: that boolean() refuses is an
  # inherited FieldAttribute - real does not validate it when the play
  # starts, it fails each task it reaches as that task runs (a skipped
  # task still skips first), with the lower chain links Origin'd at the
  # play's value token. The parser used to read it as "false" and run.
  it "fails each task that a literal play-level become: reaches" do
    root = File.tempname("become-bool-literal-play")
    Dir.mkdir(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        become: kpg-maybe
        tasks:
          - name: skipped first
            debug:
              msg: skipped
            when: false
          - name: configuration data
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'become'.").must_equal(true, output_text)
    output_text.includes?("skipping: [localhost]").must_equal(true, output_text)
    output_text.includes?("\"msg\": \"hi\"").must_equal(false, output_text)
    # The keyword and conversion links sit at the play's become value;
    # the outer link at the failing task's own line.
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:4:11").must_equal(true, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:10:7").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # A block-level value reaches the block's children the same way, and
  # its chain points at the BLOCK's value token, not the child's line.
  it "labels a block-level literal become: failure at the block's value" do
    root = File.tempname("become-bool-literal-block")
    Dir.mkdir(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: a block
            become: kpg-maybe
            block:
              - name: inside
                debug:
                  msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("\"msg\": \"hi\"").must_equal(false, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:6:15").must_equal(true, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:8:11").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails a task that writes its own literal become: value" do
    root = File.tempname("become-bool-literal-task")
    Dir.mkdir(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: configuration data
            become: kpg-maybe
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("\"msg\": \"hi\"").must_equal(false, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:6:15").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # A role's tasks load at RUN time, even for a static import_role:, so
  # the value has to ride the include statement down to them (real never
  # validates the unconvertible keyword on the import statement itself).
  it "fails the tasks an import_role under an unconvertible play become: loads" do
    root = File.tempname("become-bool-literal-import-role")
    Dir.mkdir_p(File.join(root, "roles", "testrole", "tasks"))
    role_task = File.join(root, "roles", "testrole", "tasks", "main.yml")
    File.write(role_task, <<-YAML)
      - name: role task
        debug:
          msg: hi
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        become: kpg-maybe
        tasks:
          - name: load role
            import_role:
              name: testrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("\"msg\": \"hi\"").must_equal(false, output_text)
    output_text.includes?("Origin: #{role_task}:1:3").must_equal(true, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:4:11").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # An include's apply: mapping is the implicit block its loaded tasks run
  # under, so an unconvertible become: there shadows the ambient one and
  # its token labels the loaded task's chain (real runs the include, then
  # fails the first task it loads).
  it "fails the tasks an include's apply: become: refuses" do
    root = File.tempname("become-bool-literal-include-apply")
    Dir.mkdir(root)
    included = File.join(root, "inc.yml")
    File.write(included, <<-YAML)
      - name: loaded
        debug:
          msg: loaded
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: inc
            include_tasks:
              file: inc.yml
              apply:
                become: kpg-maybe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("\"msg\": \"loaded\"").must_equal(false, output_text)
    output_text.includes?("Origin: #{included}:1:3").must_equal(true, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:9:19").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # The implicit Gathering Facts task inherits the play's become: too, and
  # real post-validates it on that task's PlayContext before resolving the
  # connection or become plugin, so it fails there first with the bare
  # "Task failed." segment (the implicit task has no source position).
  it "fails the implicit Gathering Facts task on an unconvertible play become:" do
    root = File.tempname("become-bool-literal-gather")
    Dir.mkdir(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        become: kpg-maybe
        tasks:
          - name: configuration data
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("TASK [Gathering Facts]").must_equal(true, output_text)
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("\"changed\": false, \"msg\": \"Task failed: Error processing keyword 'become'").must_equal(true, output_text)
    output_text.includes?("ok: [localhost]").must_equal(false, output_text)
    output_text.includes?("\"msg\": \"hi\"").must_equal(false, output_text)
    output_text.includes?("Origin: #{File.join(root, "pb.yml")}:3:11").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #1505: include_vars: is parsed by its own dedicated parser,
  # which never applied become: - so an unconvertible play- or task-level
  # become: left the task's become_invalid nil, the executor's keyword
  # probe never fired, and the task reported ok where real post-validates
  # the keyword and fails it before loading anything.
  it "fails an include_vars: task on an unconvertible play become:" do
    root = File.tempname("become-bool-include-vars")
    Dir.mkdir(root)
    File.write(File.join(root, "vars.yml"), "loaded_var: hi\n")
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        become: kpg-maybe
        tasks:
          - name: load vars
            include_vars:
              file: vars.yml
              name: loaded
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("TASK [load vars]").must_equal(true, output_text)
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'become'.").must_equal(true, output_text)
    output_text.includes?("ok: [localhost]").must_equal(false, output_text)
    output_text.includes?(File.join(root, "pb.yml") + ":4:11").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # A delegated include_vars: labels its fatal line `host -> delegate`
  # (CallbackBase.host_label) even though the keyword failure happens
  # controller-side before any connection is built.
  it "labels a delegated include_vars: keyword failure with the delegate:" do
    root = File.tempname("become-bool-include-vars-delegate")
    Dir.mkdir(root)
    File.write(File.join(root, "vars.yml"), "loaded_var: hi\n")
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: hostone
        connection: local
        gather_facts: false
        become: kpg-maybe
        tasks:
          - name: load vars
            include_vars:
              file: vars.yml
              name: loaded
            delegate_to: hosttwo
      YAML

    inventory = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-two-local-hosts.ini")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("fatal: [hostone -> hosttwo]: FAILED!").must_equal(true, output_text)
    output_text.includes?("ok: [hostone").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # validate_argument_spec: shares include_vars:'s dedicated-parser gap
  # (issue #1505): real treats it as an ordinary task, so its become: is
  # post-validated before the action's own argument checking runs.
  it "fails a validate_argument_spec: task on an unconvertible play become:" do
    root = File.tempname("become-bool-validate-args")
    Dir.mkdir(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        become: kpg-maybe
        tasks:
          - name: validate args
            validate_argument_spec:
              argument_spec:
                foo:
                  type: str
              provided_arguments:
                foo: bar
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("TASK [validate args]").must_equal(true, output_text)
    output_text.includes?("The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("ok: [localhost]").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Real post-validates the keywords per loop ITEM, so a looped
  # include_vars: prints one failed item line per iteration (the [ERROR]
  # block dedupes to one) and books a single failed=1, with no aggregate
  # "One or more items failed" fatal for the action.
  it "fails each item of a looped include_vars: on an unconvertible become:" do
    root = File.tempname("become-bool-include-vars-loop")
    Dir.mkdir(root)
    File.write(File.join(root, "vars.yml"), "loaded_var: hi\n")
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        become: kpg-maybe
        tasks:
          - name: load vars
            include_vars:
              file: "{{ item }}"
              name: loaded
            loop:
              - vars.yml
              - vars.yml
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.scan(/failed: \[localhost\] \(item=vars.yml\) => \{"ansible_loop_var": "item", "changed": false, "item": "vars.yml", "msg": "Task failed: Error processing keyword 'become'/).size.must_equal(2, output_text)
    output_text.includes?("One or more items failed").must_equal(false, output_text)
    output_text.includes?("failed=1").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

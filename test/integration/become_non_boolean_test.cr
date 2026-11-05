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
end

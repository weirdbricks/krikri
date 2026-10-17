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

  it "fails the play's FIRST task before Gathering Facts runs (no facts ok, ok=0)" do
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
    # Real templates the play's first task's keywords per host BEFORE the
    # implicit facts task, so the banner never prints and nothing counts
    # as ok; the failure value is still the real username.
    output_text.includes?("Gathering Facts").must_equal(false, output_text)
    # The rendered value is the controller's own user - the same
    # getpwuid identity the seeded pre-facts context carries.
    output_text.includes?("The value '#{`id -un`.strip}' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.includes?("ok=0").must_equal(true, output_text)
    output_text.includes?("failed=1").must_equal(true, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

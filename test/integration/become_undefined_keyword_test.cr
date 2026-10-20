require "../minitest_helper"
require "file_utils"

# Regression spec for issue #159: a templated task-level become: whose
# reference is UNDEFINED fails the task at keyword-templating time in real
# ansible ("Error processing keyword 'become': 'ansible_user_id' is
# undefined") - with gather_facts: false the var never becomes a gathered
# fact. krikri used to render the lenient "undefined" sentinel and fail
# later with the could-not-convert-to-bool wording instead.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a become: on an undefined variable fails with ansible's keyword error" do
  it "fails a become: on the un-gathered ansible_user_id with the keyword undefined error" do
    root = File.tempname("become-undefined-keyword")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
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
    output_text.includes?("Error processing keyword 'become': 'ansible_user_id' is undefined").must_equal(true, output_text)
    output_text.includes?("could not be converted to 'bool'").must_equal(false, output_text)
    # The task never ran: the keyword fails before any action plugin.
    output_text.includes?("msg\": \"hi\"").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails a become: on a plain missing variable with the keyword undefined error" do
    root = File.tempname("become-undefined-keyword-missing")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: configuration data
            become: "{{ nope_var }}"
            debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("Error processing keyword 'become': 'nope_var' is undefined").must_equal(true, output_text)
    output_text.includes?("could not be converted to 'bool'").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still runs a become: on a defined templated boolean" do
    root = File.tempname("become-defined-boolean")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: configuration data
            become: "{{ be_true }}"
            debug:
              msg: hi
        vars:
          be_true: "yes"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    output_text = output.to_s
    output_text.includes?("msg\": \"hi\"").must_equal(true, output_text)
    output_text.includes?("is undefined").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

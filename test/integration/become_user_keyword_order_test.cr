require "../minitest_helper"
require "file_utils"

# Regression spec for issue #209: real ansible templates the become_user:
# keyword before it finalizes any module arg, so a task whose become_user
# AND a module arg both reference undefined variables fails with the keyword
# error ("Error processing keyword 'become_user': 'ibm_user' is undefined"),
# never the module's "Finalization of task args" error. The keyword's own
# chain then points at the variable definition that failed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "an undefined become_user: wins over an undefined module arg" do
  it "reports the become_user keyword error for a command with an undefined arg" do
    root = File.tempname("become-user-keyword-order")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: list installed packages
            become: true
            become_user: "{{ ihs_user }}"
            command: "{{ iim_path }}/tools/imcl listInstalledPackages"
        vars:
          ihs_user: "{{ ibm_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("Task failed: Error processing keyword 'become_user': 'ibm_user' is undefined").must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'become_user'.").must_equal(true, output_text)
    output_text.includes?("'iim_path' is undefined").must_equal(false, output_text)
    output_text.includes?("Finalization of task args").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end

require "../minitest_helper"
require "file_utils"

# Issue #959 (Akman.packages live round): the "FAILED - RETRYING" callback
# line shows the task's get_name(), which prefixes the role name the same
# way the TASK banner does. krikri printed the bare task name, so a retried
# role task read "Update apt cache if needed" where real reads
# "Akman.packages : Update apt cache if needed".
private BINARY    = File.join(PluginSpecHelper::PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY = File.join(PluginSpecHelper::PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "FAILED - RETRYING line for a role task" do
  it "prefixes the task name with the role name like real's get_name()" do
    tempdir = PluginSpecHelper.tmp_path("retry-role-prefix")
    FileUtils.mkdir_p(File.join(tempdir, "roles", "retryrole", "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - retryrole
      YAML
    File.write(File.join(tempdir, "roles", "retryrole", "tasks", "main.yml"), <<-YAML)
      - name: Update apt cache if needed
        ansible.builtin.command:
          cmd: /bin/false
        register: result
        retries: 2
        delay: 0
        until: result is succeeded
        ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("FAILED - RETRYING: [localhost]: retryrole : Update apt cache if needed (1 retries left).")
    text.must_include("FAILED - RETRYING: [localhost]: retryrole : Update apt cache if needed (0 retries left).")
    # The banner and the retry lines show the same name shape.
    text.must_include("TASK [retryrole : Update apt cache if needed]")
    status.success?.must_equal(true)
  end
end

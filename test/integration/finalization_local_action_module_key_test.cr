require "../minitest_helper"
require "file_utils"

# Real cans.ssh-authorize shape: a mapping-form `local_action:` names its
# module on a `module:` key, so no task line starts with the module name
# and the module key locator used to find nothing. An undefined param there
# fails the same "Finalization of task args" chain as any other undefined
# param, and ansible-core 2.19.11 still prints the full three-level block:
# the middle Origin at the `module:` key's VALUE token (the `stat`), the
# innermost one at the failing param's own value (live-captured 2.19.11).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (mapping-form local_action module key)" do
  it "prints the chain with the module: value token Origin and the param value Origin" do
    tempdir = File.tempname("final-block-local-action").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "sshauthzrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - sshauthzrole
      YAML
    # the keys directory is role-defined; only the key NAME is undefined
    File.write(File.join(role, "defaults", "main.yml"), "---\nsshauthz_keys_directory: /tmp/sshauthz-keys\n")
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - name: Ensures users public key will is in local folder
        local_action:
          module: stat
          path: "{{sshauthz_keys_directory}}/{{sshauthz_user_key_name}}"
          get_md5: false
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.stat' failed: Error while resolving value for 'path': 'sshauthz_user_key_name' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{tasks_file}:2:3")
    text.must_include("\nFinalization of task args for 'ansible.builtin.stat' failed.\nOrigin: #{tasks_file}:4:13")
    text.must_include("Error while resolving value for 'path': 'sshauthz_user_key_name' is undefined\nOrigin: #{tasks_file}:5:11\n")
    text.must_include("    ^ column 3\n")
    text.must_include("              ^ column 13\n")
    text.must_include("            ^ column 11\n")
    text.must_include("<<< caused by >>>")
    text.wont_include("Index out of bounds")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end

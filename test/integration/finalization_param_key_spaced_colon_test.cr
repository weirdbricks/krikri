require "../minitest_helper"
require "file_utils"

# A block-style param key with YAML alignment padding before its colon
# (`client_id    : "..."`, the real msghaleb.azure-vms shape, round
# round29877851) fails the same "Finalization of task args" chain as any
# other undefined param, but ansible-core 2.19.11 still points the
# innermost Origin at the VALUE token's first character ACROSS the
# padding (main.yml:16:41, the quote - caret under it), not at the module
# key line krikri used to fall back to. Live-captured against 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (spaced-colon param key)" do
  it "points the innermost Origin at the value token through the key-colon padding" do
    tempdir = File.tempname("final-block-spaced").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "spacedrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - spacedrole
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    param_line = %(      client_id                       : "{{ azure_vms_client_id }}" #e.g. 6359f1g62-6543-6789-124f-398763x98112)
    File.write(tasks_file, "- name: Set the default client id\n  ansible.builtin.set_fact:\n#{param_line}\n")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'client_id': 'azure_vms_client_id' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{tasks_file}:1:3")
    text.must_include("\nFinalization of task args for 'ansible.builtin.set_fact' failed.\nOrigin: #{tasks_file}:2:3")
    text.must_include("Error while resolving value for 'client_id': 'azure_vms_client_id' is undefined\nOrigin: #{tasks_file}:3:41\n")
    text.must_include("                                          ^ column 41\n")
    text.wont_include("Index out of bounds")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "counts padding tabs one column each, still landing on the value token" do
    tempdir = File.tempname("final-block-tabbed").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "spacedrole2")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - spacedrole2
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    # real (ansible 2.19.11) for this line: main.yml:3:20, the quote after
    # `client_id\t\t: ` - a tab is one column, so the value token is at
    # 6 spaces + 9 key chars + 2 tabs + colon + space = column 20.
    File.write(tasks_file, %(- name: Set the default client id\n  ansible.builtin.set_fact:\n      client_id\t\t: "{{ azure_vms_client_id }}"\n))
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Error while resolving value for 'client_id': 'azure_vms_client_id' is undefined\nOrigin: #{tasks_file}:3:20\n")
    text.must_include("                     ^ column 20\n")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end

require "../minitest_helper"
require "file_utils"

# A `when:` LIST item whose clause ends in a quote character (issue #611)
# must still match its raw text for the "caused by" Origin lookup: the
# trailing `"` is part of the clause itself, not YAML wrapping.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "when: list item clause ending in a quote (chain Origin)" do
  it "prints real's chain with the list item's own Origin despite the trailing quote" do
    root = PluginSpecHelper.tmp_path("when-list-quoted-clause")
    role_dir = File.join(root, "j611")
    FileUtils.mkdir_p(File.join(role_dir, "tasks"))
    main_file = File.join(role_dir, "tasks", "main.yml")
    File.write(main_file, <<-YAML)
      ---
      - name: create group
        debug:
          msg: hi
        when:
          - user_setup_group != "root"
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - j611
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook],
      output: output, error: output, input: IO::Memory.new,
      env: {"ANSIBLE_ROLES_PATH" => root})

    text = output.to_s
    status.success?.must_equal(false)
    text.must_include("[ERROR]: Task failed: Error while evaluating conditional: 'user_setup_group' is undefined")
    # first link: the task's own mapping (column 3 = the `- name:` dash)
    text.must_include("Task failed.\nOrigin: #{main_file}:2:3")
    # second link: the list item's own position (column 7 = the first
    # character of the clause on the item line)
    text.must_include("<<< caused by >>>\n\nError while evaluating conditional: 'user_setup_group' is undefined\nOrigin: #{main_file}:6:7")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Error while evaluating conditional: 'user_setup_group' is undefined\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(root) if root
  end
end

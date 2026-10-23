require "../minitest_helper"
require "file_utils"

# A statically-imported task's failing `when:` lives on the IMPORTING
# file's import_tasks: line (the parser ANDed it onto the inlined task),
# so real ansible-core 2.19's two-level [ERROR] chain still prints for it
# - with the "caused by" Origin pinned at the importing file's when:
# VALUE token, not at the inlined task's own file where no `when:`
# exists (issue #252, Jooho.okd_prerequisites: okd-host.yml's first task
# reports tasks/main.yml's `when: node_type == 'okd-host'`).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "when: statically-imported conditional failure chain" do
  it "prints real's chain with the importing file's when: token Origin" do
    root = PluginSpecHelper.tmp_path("import-when-chain")
    role_dir = File.join(root, "j252")
    FileUtils.mkdir_p(File.join(role_dir, "tasks"))
    main_file = File.join(role_dir, "tasks", "main.yml")
    child_file = File.join(role_dir, "tasks", "okd-host.yml")
    File.write(main_file, <<-YAML)
      ---
      - name: Set up ocp host
        import_tasks: okd-host.yml
        when: node_type == 'okd-host'
      YAML
    File.write(child_file, <<-YAML)
      ---
      - name: Install the required rpms
        debug:
          msg: ran
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - j252
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook],
      output: output, error: output, input: IO::Memory.new,
      env: {"ANSIBLE_ROLES_PATH" => root})

    text = output.to_s
    status.success?.must_equal(false)
    text.must_include("[ERROR]: Task failed: Error while evaluating conditional: 'node_type' is undefined")
    # first link: the inlined task's own mapping, in ITS file
    text.must_include("Task failed.\nOrigin: #{child_file}:2:3\n\n1 ---\n2 - name: Install the required rpms\n    ^ column 3")
    # second link: the importing file's when: VALUE token (column 9 =
    # right after `  when: `)
    text.must_include("<<< caused by >>>\n\nError while evaluating conditional: 'node_type' is undefined\nOrigin: #{main_file}:4:9\n\n2 - name: Set up ocp host\n3   import_tasks: okd-host.yml\n4   when: node_type == 'okd-host'\n          ^ column 9")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Error while evaluating conditional: 'node_type' is undefined\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(root) if root
  end
end

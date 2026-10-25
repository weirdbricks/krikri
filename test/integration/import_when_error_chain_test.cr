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

  # A LIST-form import when: whose clause the child repeats word for word
  # in its own when: - the import clause evaluates first, so real pins the
  # chain's "caused by" Origin at the import line's list item in the
  # importing file, not at the child's identical own clause (issue #328,
  # daixijun.mysql).
  it "pins the Origin at the import's list item when the child repeats the clause" do
    root = PluginSpecHelper.tmp_path("import-when-chain-list")
    role_dir = File.join(root, "j328")
    FileUtils.mkdir_p(File.join(role_dir, "tasks"))
    main_file = File.join(role_dir, "tasks", "main.yml")
    child_file = File.join(role_dir, "tasks", "check.yml")
    File.write(main_file, <<-YAML)
      ---
      - name: Import check
        import_tasks: check.yml
        when:
          - inventory_hostname in groups[nogroup_var]
      YAML
    File.write(child_file, <<-YAML)
      ---
      - name: Child task
        debug:
          msg: ran
        when:
          - inventory_hostname in groups[nogroup_var]
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          nogroup_var: nosuchgroup
        roles:
          - j328
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook],
      output: output, error: output, input: IO::Memory.new,
      env: {"ANSIBLE_ROLES_PATH" => root})

    text = output.to_s
    text.must_include("Task failed.\nOrigin: #{child_file}:2:3")
    text.must_include("<<< caused by >>>\n\nError while evaluating conditional: object of type 'dict' has no attribute 'nosuchgroup'\nOrigin: #{main_file}:5:7")
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #333 (ivansible.lin_rclone): the failing strict conditional lies
  # TWO import levels down - tasks/main.yml's scalar `when:
  # lin_rclone_mounts |d([],true)` statically ANDed onto root.yml's own
  # import_tasks: install.yml, whose first task is a `block:` - and takes
  # its RUN-time inherit down to a plain child of that block. Real still
  # labels the fatal line with the importing file's when: value token and
  # prints the full two-level chain (Origin at the child's name line in
  # install.yml, "caused by" Origin at main.yml:5:9 with the
  # ALLOW_BROKEN_CONDITIONALS hint); the child's own file holds no
  # `when:` for either decoration to scan.
  it "prints real's chain for an imported block child two import levels deep" do
    root = PluginSpecHelper.tmp_path("import-when-chain-block")
    role_dir = File.join(root, "j333")
    FileUtils.mkdir_p(File.join(role_dir, "tasks"))
    main_file = File.join(role_dir, "tasks", "main.yml")
    root_file = File.join(role_dir, "tasks", "root.yml")
    install_file = File.join(role_dir, "tasks", "install.yml")
    File.write(main_file, <<-YAML)
      ---
      - name: Rclone setup
        import_tasks: root.yml
        become: true
        when: lin_rclone_mounts |d([],true)
      YAML
    File.write(root_file, <<-YAML)
      ---
      - name: Install rclone
        import_tasks: install.yml
      YAML
    File.write(install_file, <<-YAML)
      ---
      - name: install rclone from package
        block:
          - name: detect latest rclone package release
            ansible.builtin.file:
              state: touch
              path: /tmp/krikri-never-runs
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          lin_rclone_mounts: [/mnt/data]
        roles:
          - j333
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook],
      output: output, error: output, input: IO::Memory.new,
      env: {"ANSIBLE_ROLES_PATH" => root})

    text = output.to_s
    status.success?.must_equal(false)
    # first link: the failing child's own mapping, inside the block's
    # file (real's install.yml:4:7 shape)
    text.must_include("Task failed.\nOrigin: #{install_file}:4:7\n\n2 - name: install rclone from package\n3   block:\n4     - name: detect latest rclone package release\n        ^ column 7")
    # second link: the importing file's when: VALUE token (column 9 =
    # right after `  when: `)
    text.must_include("<<< caused by >>>\n\nConditional result (True) was derived from value of type 'list' at '#{main_file}:5:9'. Conditionals must have a boolean result.\nOrigin: #{main_file}:5:9\n\n3   import_tasks: root.yml\n4   become: true\n5   when: lin_rclone_mounts |d([],true)\n          ^ column 9")
    text.must_include("Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Conditional result (True) was derived from value of type 'list' at '#{main_file}:5:9'. Conditionals must have a boolean result.\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(root) if root
  end
end

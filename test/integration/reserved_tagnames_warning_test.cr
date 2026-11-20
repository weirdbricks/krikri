require "../minitest_helper"
require "file_utils"

# ansible-core's Taggable._load_tags warns whenever the tags it just
# loaded name one of the reserved words ('tagged'/'all'/'untagged'), for
# every Taggable object - play, block, task, roles: entry, import_tasks:
# line. The Origin points at the tags VALUE node, not at the `tags:` key:
# the opening bracket of a flow list, the first item's line of a block
# list, the scalar itself otherwise (live-verified vs 2.21.6; issue #1651
# is pgkehle.nvm's `tags: ["all"]` in a role task).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private WARNING_TEXT = "[WARNING]: Found reserved tagnames in tags: ['all'], we do not recommend doing this as it might give unexpected results"

describe "reserved tagnames warning" do
  it "warns for a role task's reserved tag with the tags value's Origin" do
    src_dir = File.tempname("reserved-tag-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "rt", "tasks"))
    tasks_file = File.join(src_dir, "roles", "rt", "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - name: Clean artifact path
        file:
          state: absent
          path: "/nonexistent/krikri-reserved-tag"
        tags: ["all"]
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - rt
      YAML

    output = IO::Memory.new
    errors = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook, "--check"], output: output, error: errors, chdir: src_dir)
    text = errors.to_s

    text.must_include(WARNING_TEXT)
    # The flow list's opening bracket - column 9 of `  tags: ["all"]`,
    # with the usual two context lines, the target line and the caret.
    text.must_include("Origin: #{tasks_file}:6:9")
    text.must_include("4     state: absent")
    text.must_include("6   tags: [\"all\"]")
    text.must_include("          ^ column 9")
    text.scan("Found reserved tagnames").size.must_equal(1)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns for a play and a block-list task tag, Origin at the first list item" do
    src_dir = File.tempname("reserved-tag-play")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tags: ["all"]
        tasks:
          - name: Block list tags
            debug:
              msg: hi
            tags:
              - all
              - foo
      YAML

    output = IO::Memory.new
    errors = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook, "--check"], output: output, error: errors, chdir: src_dir)
    text = errors.to_s

    text.scan(WARNING_TEXT).size.must_equal(2)
    text.must_include("Origin: #{playbook}:3:9")
    # A block sequence's value node starts at its first ITEM, not at the
    # `tags:` key line.
    text.must_include("Origin: #{playbook}:9:9")
    text.must_include("9         - all")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns for a roles: entry's reserved tag before the role's own tasks" do
    src_dir = File.tempname("reserved-tag-entry")
    Dir.mkdir_p(File.join(src_dir, "roles", "re", "tasks"))
    tasks_file = File.join(src_dir, "roles", "re", "tasks", "main.yml")
    File.write(tasks_file, "---\n- name: Role task\n  debug:\n    msg: hi\n  tags: [\"all\"]\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - role: re
            tags: ["all"]
      YAML

    output = IO::Memory.new
    errors = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook, "--check"], output: output, error: errors, chdir: src_dir)
    text = errors.to_s

    entry_at = text.index!("Origin: #{playbook}:5:13")
    role_at = text.index!("Origin: #{tasks_file}:5:9")
    (entry_at < role_at).must_equal(true)
    text.scan("Found reserved tagnames").size.must_equal(2)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "never warns for unreserved tags, never being a legal task tag" do
    src_dir = File.tempname("reserved-tag-clean")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tags: ["foo"]
        tasks:
          - name: Fine task
            debug:
              msg: hi
            tags: ["bar", "never"]
      YAML

    output = IO::Memory.new
    errors = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook, "--check"], output: output, error: errors, chdir: src_dir)

    refute(errors.to_s.includes?("Found reserved tagnames"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end
end

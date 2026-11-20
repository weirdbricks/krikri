require "../minitest_helper"
require "file_utils"

# ansible-core's Taggable._load_tags warns at load time for every tags
# value naming a reserved tag ('all'/'tagged'/'untagged'):
#   [WARNING]: Found reserved tagnames in tags: ['all'], we do not
#   recommend doing this as it might give unexpected results
# followed by the value's own Origin block. 'always'/'never' are ordinary
# tags there, a templated value is compared as written, and an include's
# apply:{tags:} is loaded only when the include actually runs. All
# byte-for-byte vs ansible-playbook 2.21.6 (issues #1644 and #1651, both
# pgkehle.nvm's `tags: ["all"]`).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private WARNING_TEXT = "[WARNING]: Found reserved tagnames in tags: ['all'], we do not recommend doing this as it might give unexpected results"

private def run_tagname_playbook(pb : String)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: stderr)
  {stdout.to_s, stderr.to_s}
end

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

  it "warns at load for play, task, comma-string and block tags, before the block's children" do
    dir = PluginSpecHelper.tmp_path("reserved-tagnames")
    FileUtils.mkdir_p(dir)
    pb = File.join(dir, "pb.yml")
    File.write(pb, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tags: all
        tasks:
          - name: reserved list
            debug: msg=one
            tags: ["all"]

          - name: comma string
            debug: msg=two
            tags: "all, tagged"

          - name: never and always are ordinary tags
            debug: msg=three
            tags: [never, always]

          - block:
              - name: child reserved
                debug: msg=four
                tags: [untagged]
            tags: [tagged]
      YAML

    stdout, stderr = run_tagname_playbook(pb)
    # Byte-identical block for the task-level case: the tags VALUE node's
    # mark (the `[` of the flow list), two preceding source lines, caret.
    stderr.must_include("[WARNING]: Found reserved tagnames in tags: ['all'], we do not recommend doing this as it might give unexpected results\n" \
                        "Origin: #{pb}:7:13\n\n" \
                        "5     - name: reserved list\n" \
                        "6       debug: msg=one\n" \
                        "7       tags: [\"all\"]\n" \
                        "              ^ column 13\n")
    stderr.must_include("[WARNING]: Found reserved tagnames in tags: ['all', 'tagged'], we do not recommend doing this as it might give unexpected results")
    stderr.must_include("Origin: #{pb}:3:9")
    stderr.must_include("Origin: #{pb}:11:13")
    # A block's own tags warn before the children load (real's Block.load
    # order), and `always`/`never` never warn.
    stderr.scan("Found reserved tagnames").size.must_equal(5)
    play_pos = stderr.index!("Origin: #{pb}:3:9")
    task_pos = stderr.index!("Origin: #{pb}:7:13")
    comma_pos = stderr.index!("Origin: #{pb}:11:13")
    block_pos = stderr.index!("Origin: #{pb}:21:13")
    child_pos = stderr.index!("Origin: #{pb}:20:17")
    (play_pos < task_pos).must_equal(true, stderr)
    (task_pos < comma_pos).must_equal(true, stderr)
    (comma_pos < block_pos).must_equal(true, stderr)
    (block_pos < child_pos).must_equal(true, stderr)
    stdout.must_include("\"msg\": \"four\"")
  end

  it "warns for an import statement's tags before the imported file's own tasks load" do
    dir = PluginSpecHelper.tmp_path("reserved-tagnames-import")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, <<-YAML)
      - name: child reserved
        debug: msg=child
        tags: [untagged]
      YAML
    File.write(pb, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: import with tags
            import_tasks: sub.yml
            tags: [all]
      YAML

    stdout, stderr = run_tagname_playbook(pb)
    statement_pos = stderr.index!("Origin: #{pb}:6:13")
    child_pos = stderr.index!("Origin: #{sub}:3:9")
    (statement_pos < child_pos).must_equal(true, stderr)
    stdout.must_include("\"msg\": \"child\"")
  end

  it "warns for an include's apply tags at run time and not when the include is skipped" do
    dir = PluginSpecHelper.tmp_path("reserved-tagnames-apply")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, "- debug:\n    msg: applied\n")
    File.write(pb, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: include with apply tags
            include_tasks:
              file: sub.yml
              apply:
                tags: [all]

          - name: skipped include with apply tags
            include_tasks:
              file: sub.yml
              apply:
                tags: [untagged]
            when: false
      YAML

    stdout, stderr = run_tagname_playbook(pb)
    stderr.must_include("[WARNING]: Found reserved tagnames in tags: ['all'], we do not recommend doing this as it might give unexpected results")
    stderr.must_include("Origin: #{pb}:8:17")
    # Real builds the implicit apply-Block only when the include runs, so
    # the skipped statement's tags never warn.
    stderr.scan("Found reserved tagnames").size.must_equal(1)
    stdout.must_include("included: #{File.expand_path(sub)} for localhost")
    stdout.must_include("\"msg\": \"applied\"")
  end
end

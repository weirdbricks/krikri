require "../minitest_helper"

describe "blockinfile plugin" do
  it "inserts a new block at EOF and is idempotent on rerun" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "hello\nworld"})
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\nline2\n# BEGIN ANSIBLE MANAGED BLOCK\nhello\nworld\n# END ANSIBLE MANAGED BLOCK\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "hello\nworld"})
    result["changed"].as_bool.must_equal(false)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "updates an existing block's content without moving it" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nold\n# END ANSIBLE MANAGED BLOCK\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "new"})
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\n# BEGIN ANSIBLE MANAGED BLOCK\nnew\n# END ANSIBLE MANAGED BLOCK\nline2\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "removes an existing block on state: absent" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "state" => "absent"})
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\nline2\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "treats an empty block as absent regardless of state" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => ""})
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\nline2\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "supports custom markers" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n")

    result = PluginSpecHelper.run("blockinfile", {
      "path" => path, "block" => "custom", "marker" => "// {mark} MYBLOCK", "marker_begin" => "START", "marker_end" => "STOP",
    })
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\n// START MYBLOCK\ncustom\n// STOP MYBLOCK\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "inserts before a regexp match via insertbefore" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\nline2\nline3\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "insertbefore" => "^line2"})
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\nline2\nline3\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "creates a missing file when create: true, reporting File created" do
    path = File.tempname("blockinfile-spec")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "create" => "true", "block" => "alpha\nbeta"})
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("File created")
    File.read(path).must_equal("# BEGIN ANSIBLE MANAGED BLOCK\nalpha\nbeta\n# END ANSIBLE MANAGED BLOCK\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "fails clearly when the file is missing and create is not given" do
    path = File.tempname("blockinfile-spec")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x"})
    result["failed"].as_bool.must_equal(true)
  end

  it "reports check mode without writing" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "_ansible_check_mode" => "true"})
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("line1\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  # Unlike lineinfile (whose key is `backup`), real Ansible's blockinfile
  # exits with `backup_file` (blockinfile.py: exit_json(..., backup_file=...),
  # key omitted entirely when no backup was made). Live-verified against
  # ansible-core 2.19.11 - pinned here so nobody "unifies" the two names.
  it "reports the backup path under the 'backup_file' key with backup: yes" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "old\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "new", "backup" => "yes"})
    backup = result["backup_file"].as_s

    backup.wont_be_empty
    File.exists?(backup).must_equal(true)
    File.read(backup).must_equal("old\n")

    File.delete(path) if File.exists?(path)
    File.delete(backup)
  end

  # An empty block: (real's default) means "remove the block", but the
  # task is still state: present - and real gates prepend_newline /
  # append_newline on that alone, not on there being a block to insert.
  # Folding the two together dropped the blank line they add and
  # reported ok; real adds it and reports changed with "Block removed"
  # (live-verified against ansible-core 2.19.11 with a task carrying
  # only create/marker/prepend_newline/append_newline).
  it "still pads the file with prepend_newline/append_newline when the block is empty" do
    path = PluginSpecHelper.tmp_path("blockinfile-empty-block-padding.txt")
    File.write(path, "key = value\nkpg setting = on\n")

    result = PluginSpecHelper.run("blockinfile", {
      "path"            => path,
      "create"          => "true",
      "marker"          => "# {mark} KPG BLOCK",
      "marker_begin"    => "BEGIN",
      "marker_end"      => "END",
      "prepend_newline" => "true",
      "append_newline"  => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Block removed")
    File.read(path).must_equal("key = value\nkpg setting = on\n\n")
  end

  it "is idempotent on a second run of the empty-block padding case" do
    path = PluginSpecHelper.tmp_path("blockinfile-empty-block-padding-rerun.txt")
    File.write(path, "key = value\n")

    PluginSpecHelper.run("blockinfile", {"path" => path, "prepend_newline" => "true"})
    result = PluginSpecHelper.run("blockinfile", {"path" => path, "prepend_newline" => "true"})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("")
    File.read(path).must_equal("key = value\n\n")
  end

  it "creates a missing file even with an empty block, reporting File created" do
    dir = PluginSpecHelper.tmp_path("blockinfile-empty-block-create")
    FileUtils.rm_rf(dir)
    path = File.join(dir, "new.txt")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "create" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("File created")
    File.read(path).must_equal("")
  end
end

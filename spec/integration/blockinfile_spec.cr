require "../spec_helper"

describe "blockinfile plugin" do
  it "inserts a new block at EOF and is idempotent on rerun" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "hello\nworld"})
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\nline2\n# BEGIN ANSIBLE MANAGED BLOCK\nhello\nworld\n# END ANSIBLE MANAGED BLOCK\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "hello\nworld"})
    result["changed"].as_bool.should be_false
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "updates an existing block's content without moving it" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nold\n# END ANSIBLE MANAGED BLOCK\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "new"})
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\n# BEGIN ANSIBLE MANAGED BLOCK\nnew\n# END ANSIBLE MANAGED BLOCK\nline2\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "removes an existing block on state: absent" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "state" => "absent"})
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\nline2\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "treats an empty block as absent regardless of state" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\nline2\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => ""})
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\nline2\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "supports custom markers" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n")

    result = PluginSpecHelper.run("blockinfile", {
      "path" => path, "block" => "custom", "marker" => "// {mark} MYBLOCK", "marker_begin" => "START", "marker_end" => "STOP",
    })
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\n// START MYBLOCK\ncustom\n// STOP MYBLOCK\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "inserts before a regexp match via insertbefore" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\nline2\nline3\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "insertbefore" => "^line2"})
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\n# BEGIN ANSIBLE MANAGED BLOCK\nx\n# END ANSIBLE MANAGED BLOCK\nline2\nline3\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "creates a missing file when create: true, reporting File created" do
    path = File.tempname("blockinfile-spec")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "create" => "true", "block" => "alpha\nbeta"})
    result["changed"].as_bool.should be_true
    result["msg"].as_s.should eq("File created")
    File.read(path).should eq("# BEGIN ANSIBLE MANAGED BLOCK\nalpha\nbeta\n# END ANSIBLE MANAGED BLOCK\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "fails clearly when the file is missing and create is not given" do
    path = File.tempname("blockinfile-spec")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x"})
    result["failed"].as_bool.should be_true
  end

  it "reports check mode without writing" do
    path = File.tempname("blockinfile-spec")
    File.write(path, "line1\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "x", "_ansible_check_mode" => "true"})
    result["changed"].as_bool.should be_true
    File.read(path).should eq("line1\n")
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

    backup.should_not be_empty
    File.exists?(backup).should be_true
    File.read(backup).should eq("old\n")

    File.delete(path) if File.exists?(path)
    File.delete(backup)
  end
end

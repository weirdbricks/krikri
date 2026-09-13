require "../spec_helper"
require "file_utils"
require "system/user"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "replace")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def fresh_file(name : String, content : String) : String
  path = File.join(TMP_DIR, name)
  File.write(path, content)
  path
end

describe "replace plugin" do
  it "replaces a regex match in the file" do
    path = fresh_file("one.conf", "  gpgcheck = 0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^\\s*gpgcheck.*", "replace" => "gpgcheck=1"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("gpgcheck=1\n")
  end

  it "reports changed: false on an idempotent rerun" do
    path = fresh_file("idem.conf", "gpgcheck=1\n")
    params = {"path" => path, "regexp" => "^\\s*gpgcheck.*", "replace" => "gpgcheck=1"}
    PluginSpecHelper.run("replace", params)

    result = PluginSpecHelper.run("replace", params)

    result["changed"].as_bool.should be_false
  end

  it "anchors ^ and $ at line boundaries (real Ansible's re.MULTILINE)" do
    # The inmotionhosting.wordpress round-82013 divergence: real Ansible's
    # replace.py compiles with re.MULTILINE, so "Listen 443$" matches the
    # tab-indented Listen lines inside <IfModule> blocks mid-file; without
    # MULTILINE only an end-of-file match counts and the task misreports ok.
    path = fresh_file("ports.conf", "Listen 80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n\n<IfModule mod_gnutls.c>\n\tListen 443\n</IfModule>\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "Listen 443$", "replace" => "Listen 8443"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("Listen 80\n\n<IfModule ssl_module>\n\tListen 8443\n</IfModule>\n\n<IfModule mod_gnutls.c>\n\tListen 8443\n</IfModule>\n")
  end

  it "reports changed: false when the replacement is identical to the match" do
    path = fresh_file("same.conf", "Listen 80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "Listen 443$", "replace" => "Listen 443"})

    result["changed"].as_bool.should be_false
    File.read(path).should eq("Listen 80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n")
  end

  it "applies mode when given" do
    path = fresh_file("mode.conf", "x=1\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^x", "replace" => "y", "mode" => "0600"})

    result["changed"].as_bool.should be_true
    (File.info(path, follow_symlinks: false).permissions.value & 0o777).should eq(0o600)
  end

  it "accepts owner/group and reports add_path_info stat fields (add_file_common_args)" do
    me = System::User.find_by?(id: LibC.getuid.to_s).try(&.username) || ENV["USER"]? || "root"
    path = fresh_file("owner.conf", "x=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^x", "replace" => "y", "owner" => me, "group" => me, "mode" => "0600"})

    result["failed"]?.should be_nil
    result["owner"].as_s.should eq(me)
    result["group"].as_s.should eq(me)
    result["mode"].as_s.should eq("0600")
  end

  it "restricts substitution to content after the first `after` match" do
    path = fresh_file("after.conf", "keep-a=1\n[main]\nchange-a=1\nchange-b=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "\\[main\\]", "regexp" => "^change-", "replace" => "fixed-"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("keep-a=1\n[main]\nfixed-a=1\nfixed-b=1\n")
  end

  it "restricts substitution to content before the last `before` match" do
    # Python's greedy `(?P<subsection>.*)before` under re.search anchors the
    # section at position 0 and backtracks to the LAST occurrence of before.
    path = fresh_file("before.conf", "change-a=1\nchange-b=1\n[main]\nkeep-b=1\n[main]\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "before" => "\\[main\\]", "regexp" => "^change-", "replace" => "fixed-"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("fixed-a=1\nfixed-b=1\n[main]\nkeep-b=1\n[main]\n")
  end

  it "restricts substitution to the region between after and before (both given)" do
    path = fresh_file("both.conf", "<VirtualHost *>\n  Line1\n  Line2\n</VirtualHost>\nother\n")

    # after/before are compiled with re.DOTALL only (no re.MULTILINE) in
    # real Ansible - `^`/`$` inside them anchor to the whole-content
    # start/end, not line boundaries, so unanchored literals are used here
    # (live-verified against real Python's re module with this exact
    # module.py pattern-construction logic).
    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "<VirtualHost \\*>", "before" => "</VirtualHost>", "regexp" => "^(.+)$", "replace" => "# \\1"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("<VirtualHost *>\n#   Line1\n#   Line2\n</VirtualHost>\nother\n")
  end

  it "reports changed: false (not failed) when before/after matches nothing" do
    path = fresh_file("nomatch.conf", "a=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "NOPE", "regexp" => "^a", "replace" => "b"})

    result["changed"].as_bool.should be_false
    result["failed"]?.should be_nil
    result["msg"].as_s.should contain("did not match the given file")
    File.read(path).should eq("a=1\n")
  end

  it "creates a timestamped backup and reports backup_file when backup: yes" do
    path = fresh_file("backup.conf", "gpgcheck=0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "gpgcheck=0", "replace" => "gpgcheck=1", "backup" => "yes"})

    result["changed"].as_bool.should be_true
    backup_file = result["backup_file"].as_s
    File.exists?(backup_file).should be_true
    File.read(backup_file).should eq("gpgcheck=0\n")
    File.read(path).should eq("gpgcheck=1\n")
  end

  it "creates no backup without backup: yes" do
    path = fresh_file("nobackup.conf", "gpgcheck=0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "gpgcheck=0", "replace" => "gpgcheck=1"})

    result["changed"].as_bool.should be_true
    result["backup_file"].as_s.should be_empty
    Dir[File.join(TMP_DIR, "nobackup.conf*")].size.should eq(1)
  end

  it "passes validation and writes the file (validate: with %s)" do
    path = fresh_file("validate-ok.conf", "value=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "value=1", "replace" => "value=2", "validate" => "grep -q '^value=2' %s"})

    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true
    File.read(path).should eq("value=2\n")
  end

  it "fails validation and leaves the real file untouched" do
    path = fresh_file("validate-fail.conf", "value=BAD\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^value=.*", "replace" => "value=STILL_BAD", "validate" => "! grep -q 'BAD' %s"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("failed to validate")
    File.read(path).should eq("value=BAD\n")
  end

  it "fails when validate does not contain %s" do
    path = fresh_file("validate-nos.conf", "value=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "value=1", "replace" => "value=2", "validate" => "/bin/true"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("validate must contain %s")
  end

  it "reads and writes with the given encoding" do
    path = File.join(TMP_DIR, "encoding.txt")
    File.write(path, "caf".to_slice + Bytes[0xe9] + "=1".to_slice)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "=1", "replace" => "=2", "encoding" => "latin1"})

    result["changed"].as_bool.should be_true
    bytes = File.read(path).to_slice
    bytes[-1].should eq('2'.ord)
    bytes[3].should eq(0xe9)
  end

  it "fails when the file doesn't exist" do
    result = PluginSpecHelper.run("replace", {"path" => File.join(TMP_DIR, "nope.txt"), "regexp" => "x", "replace" => "y"})

    result["failed"].as_bool.should be_true
  end

  it "fails when regexp is missing" do
    path = fresh_file("noregexp.txt", "x")
    result = PluginSpecHelper.run("replace", {"path" => path})

    result["failed"].as_bool.should be_true
  end
end

require "../minitest_helper"

describe "tempfile plugin" do
  it "creates a temporary file by default and reports changed" do
    result = PluginSpecHelper.run("tempfile", {} of String => String)

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    path = result["path"].as_s
    File.exists?(path).must_equal(true)
    File.file?(path).must_equal(true)
    File.delete(path)
  end

  it "creates a temporary directory when state: directory" do
    result = PluginSpecHelper.run("tempfile", {"state" => "directory"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    path = result["path"].as_s
    Dir.exists?(path).must_equal(true)
    Dir.delete(path)
  end

  it "honors prefix and suffix" do
    result = PluginSpecHelper.run("tempfile", {"prefix" => "myapp.", "suffix" => ".conf"})

    path = result["path"].as_s
    File.basename(path).starts_with?("myapp.").must_equal(true)
    File.basename(path).ends_with?(".conf").must_equal(true)
    File.delete(path)
  end

  it "creates the file under path: when given" do
    dir = File.join(PluginSpecHelper::PROJECT_ROOT, "test", "tmp")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("tempfile", {"path" => dir})

    path = result["path"].as_s
    File.dirname(path).must_equal(dir)
    File.delete(path)
  end

  it "fails for an invalid state" do
    result = PluginSpecHelper.run("tempfile", {"state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: file, directory, got: bogus")
  end

  it "fails when path: doesn't exist" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all"})

    result["failed"].as_bool.must_equal(true)
  end

  # Real's tempfile module hands `path` straight to Python's
  # tempfile.mkstemp/mkdtemp and reports the resulting OSError verbatim, so
  # a missing directory yields an errno-shaped message quoting the full
  # path it tried to create - not a module-specific sentence. Only
  # mkstemp's own 8 random characters differ per run (the parity harness
  # masks exactly those); everything around them is fixed.
  it "reports a missing directory as real's Errno 2, quoting the full path" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all", "suffix" => ".txt"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_match(/^\[Errno 2\] No such file or directory: '\/no\/such\/dir\/at\/all\/ansible\.[a-z0-9_]{8}\.txt'$/)
  end

  it "uses the default prefix and an empty suffix in the missing-directory message" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all"})

    result["msg"].as_s.must_match(/'\/no\/such\/dir\/at\/all\/ansible\.[a-z0-9_]{8}'$/)
  end

  it "honors a custom prefix in the missing-directory message" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all", "prefix" => "pre_"})

    result["msg"].as_s.must_match(/'\/no\/such\/dir\/at\/all\/pre_[a-z0-9_]{8}'$/)
  end

  it "reports a missing directory the same way for state: directory" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all", "state" => "directory", "suffix" => ".cfg"})

    result["msg"].as_s.must_match(/^\[Errno 2\] No such file or directory: '\/no\/such\/dir\/at\/all\/ansible\.[a-z0-9_]{8}\.cfg'$/)
  end

  it "reports a path that exists but is not a directory as Errno 20" do
    dir = File.join(PluginSpecHelper::TEST_TMP_BASE, "tempfile-not-a-dir")
    Dir.mkdir_p(dir)
    file = File.join(dir, "plain-file")
    File.write(file, "")

    result = PluginSpecHelper.run("tempfile", {"path" => file})

    result["msg"].as_s.must_match(/^\[Errno 20\] Not a directory: '#{Regex.escape(file)}\/ansible\.[a-z0-9_]{8}'$/)
    File.delete(file)
  end

  # AnsibleModule's type='path' runs unfrackpath, so a relative path is
  # resolved against the module's own working directory (and normalized)
  # before it ever reaches mkstemp - and it is that absolute form real
  # quotes in the error.
  it "resolves a relative path: against the working directory in the error" do
    dir = File.join(PluginSpecHelper::TEST_TMP_BASE, "tempfile-rel")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("tempfile", {"path" => "./no_such_dir_here", "suffix" => ".txt"}, chdir: dir)

    result["msg"].as_s.must_match(/^\[Errno 2\] No such file or directory: '#{Regex.escape(File.real_path(dir))}\/no_such_dir_here\/ansible\.[a-z0-9_]{8}\.txt'$/)
  end

  # Real's local connection plugin runs every module with cwd = the
  # playbook's directory, not the shell's cwd the playbook was launched
  # from - so with a `playbook_dir` in scope, that (not the plugin
  # process's own cwd) is what a relative path resolves against.
  it "resolves a relative path: against playbook_dir, not the process cwd" do
    basedir = File.join(PluginSpecHelper::TEST_TMP_BASE, "tempfile-pbdir")
    Dir.mkdir_p(basedir)
    elsewhere = File.join(PluginSpecHelper::TEST_TMP_BASE, "tempfile-elsewhere")
    Dir.mkdir_p(elsewhere)

    result = PluginSpecHelper.run("tempfile", {"path" => "no_such_dir_here"}, {"playbook_dir" => basedir}, chdir: elsewhere)

    result["msg"].as_s.must_match(/^\[Errno 2\] No such file or directory: '#{Regex.escape(File.real_path(basedir))}\/no_such_dir_here\/ansible\.[a-z0-9_]{8}'$/)
  end

  it "normalizes . and .. in path: like real's unfrackpath" do
    basedir = File.join(PluginSpecHelper::TEST_TMP_BASE, "tempfile-norm")
    Dir.mkdir_p(File.join(basedir, "sub"))

    result = PluginSpecHelper.run("tempfile", {"path" => "./sub/../no_such_dir_here/"}, {"playbook_dir" => basedir})

    result["msg"].as_s.must_match(/^\[Errno 2\] No such file or directory: '#{Regex.escape(File.real_path(basedir))}\/no_such_dir_here\/ansible\.[a-z0-9_]{8}'$/)
  end
end

require "../minitest_helper"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "cronvar plugin" do
  it "creates the cron_file and adds the variable" do
    path = tmp_path("cronvar-create.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "admin@example.com",
      "cron_file" => path,
    })

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("MAILTO=admin@example.com")
  end

  it "resolves a relative cron_file: against /etc/cron.d, matching real Ansible" do
    # Same proof shape as cron_spec's relative-path example. The
    # observable evidence of correct resolution depends on privilege:
    # unprivileged, a permission error at exactly the resolved path;
    # as root (CI's job container), the file is actually created there.
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "root",
      "cron_file" => "krikri-playbook-spec-relative",
    })

    resolved = "/etc/cron.d/krikri-playbook-spec-relative"
    if File.writable?("/etc/cron.d")
      # failed is a JSON::Any - normalize via as_bool, and use be_falsey:
      # a JSON::Any(false) is not == false for the matcher, and a SUCCESS
      # result omits the failed key entirely (nil) - the path that runs
      # on a root CI container where /etc/cron.d is writable.
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.read(resolved).must_include("MAILTO=root")
      File.delete(resolved)
    else
      result["failed"]?.try(&.as_bool).must_equal(true)
      result["msg"].as_s.must_include(resolved)
    end
  end

  it "is idempotent on a second run with the same parameters" do
    path = tmp_path("cronvar-idempotent.txt")
    File.delete(path) if File.exists?(path)
    params = {
      "name"      => "MAILTO",
      "value"     => "root",
      "cron_file" => path,
    }

    first = PluginSpecHelper.run("cronvar", params)
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("cronvar", params)
    second["changed"].as_bool.must_equal(false)
  end

  it "updates the value in place when it changes" do
    path = tmp_path("cronvar-update.txt")
    PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "ops@example.com", "cron_file" => path})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("MAILTO=ops@example.com")
    content.wont_include("MAILTO=root")
  end

  it "is a no-op on an assignment that already holds the value, even with spaces around the = (real module only rewrites when the parsed value differs)" do
    path = tmp_path("cronvar-spaces.txt")
    File.write(path, "MAILTO = root\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal("MAILTO = root\n")
  end

  it "removes the variable when state=absent" do
    path = tmp_path("cronvar-remove.txt")
    File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.wont_include("MAILTO")
    content.must_include("SHELL=/bin/sh")
  end

  it "is a no-op removing a variable that isn't there" do
    path = tmp_path("cronvar-absent-noop.txt")
    File.write(path, "SHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.must_equal(false)
  end

  it "leaves crontab schedule lines in the file untouched" do
    path = tmp_path("cronvar-schedule.txt")
    File.write(path, "SHELL=/bin/sh\n#Ansible: nightly backup\n0 2 * * * /bin/backup\n")

    PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    content = File.read(path)
    content.must_include("#Ansible: nightly backup")
    content.must_include("0 2 * * * /bin/backup")
    content.must_include("MAILTO=root")
  end

  it "returns the current variable list in vars" do
    path = tmp_path("cronvar-vars.txt")
    File.write(path, "SHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result["vars"].as_a.map(&.as_s).must_equal(["MAILTO", "SHELL"])
  end

  it "supports insertafter positioning for a new variable" do
    path = tmp_path("cronvar-insertafter.txt")
    File.write(path, "SHELL=/bin/sh\nMAILTO=root\n")

    result = PluginSpecHelper.run("cronvar", {
      "name"        => "PATH",
      "value"       => "/usr/local/bin",
      "cron_file"   => path,
      "insertafter" => "SHELL",
    })

    result["changed"].as_bool.must_equal(true)
    lines = File.read(path).split("\n")
    lines.index("SHELL=/bin/sh").must_equal(0)
    lines.index("PATH=/usr/local/bin").must_equal(1)
  end

  it "does not write to disk in check mode" do
    path = tmp_path("cronvar-check-mode.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cronvar", {
      "name"                => "MAILTO",
      "value"               => "root",
      "cron_file"           => path,
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(false)
  end

  it "writes a timestamped backup before changing when backup=true" do
    path = tmp_path("cronvar-backup.txt")
    File.write(path, "MAILTO=root\n")

    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "ops@example.com",
      "cron_file" => path,
      "backup"    => "true",
    })

    result["changed"].as_bool.must_equal(true)
    backup_file = result["backup_file"].as_s
    File.exists?(backup_file).must_equal(true)
    File.read(backup_file).must_equal("MAILTO=root\n")
  end

  it "fails with the real module's message when value is missing for state=present" do
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "cron_file" => tmp_path("cronvar-missing-value.txt"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("You must specify 'value' to insert a new cron variable")
  end

  it "fails when insertbefore and insertafter are both given" do
    result = PluginSpecHelper.run("cronvar", {
      "name"         => "MAILTO",
      "value"        => "root",
      "cron_file"    => tmp_path("cronvar-mutually-exclusive.txt"),
      "insertafter"  => "SHELL",
      "insertbefore" => "SHELL",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("mutually exclusive")
  end

  # Real community.general cronvar's result shape (live-verified against
  # ansible-core 2.19.11): changed + vars (the full current var-name
  # list), plus cron_file/backup_file only when they apply - a backup
  # key is present ONLY when a backup was actually retained.
  describe "result shape (real ansible's field set)" do
    it "carries vars as the full current var-name list after the change" do
      path = tmp_path("cronvar-shape.txt")
      File.delete(path) if File.exists?(path)

      PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})
      result = PluginSpecHelper.run("cronvar", {"name" => "SHELL", "value" => "/bin/sh", "cron_file" => path})

      result["vars"].as_a.map(&.as_s).must_equal(["SHELL", "MAILTO"])
      result["changed"].as_bool.must_equal(true)
    end

    it "omits backup_file when no backup was made" do
      path = tmp_path("cronvar-no-backup.txt")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

      result["backup_file"]?.must_be_nil
    end
  end
end

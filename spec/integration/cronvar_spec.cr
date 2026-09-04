require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
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

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("MAILTO=admin@example.com")
  end

  it "resolves a relative cron_file: against /etc/cron.d, matching real Ansible" do
    # Same proof shape as cron_spec's relative-path example: this spec
    # runs unprivileged, so a permission error at exactly the resolved
    # path is the observable evidence of correct resolution.
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "root",
      "cron_file" => "krikri-playbook-spec-relative",
    })

    result["failed"]?.try(&.as_bool).should be_true
    result["msg"].as_s.should contain("/etc/cron.d/krikri-playbook-spec-relative")
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
    first["changed"].as_bool.should be_true

    second = PluginSpecHelper.run("cronvar", params)
    second["changed"].as_bool.should be_false
  end

  it "updates the value in place when it changes" do
    path = tmp_path("cronvar-update.txt")
    PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "ops@example.com", "cron_file" => path})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("MAILTO=ops@example.com")
    content.should_not contain("MAILTO=root")
  end

  it "is a no-op on an assignment that already holds the value, even with spaces around the = (real module only rewrites when the parsed value differs)" do
    path = tmp_path("cronvar-spaces.txt")
    File.write(path, "MAILTO = root\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result["changed"].as_bool.should be_false
    File.read(path).should eq("MAILTO = root\n")
  end

  it "removes the variable when state=absent" do
    path = tmp_path("cronvar-remove.txt")
    File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should_not contain("MAILTO")
    content.should contain("SHELL=/bin/sh")
  end

  it "is a no-op removing a variable that isn't there" do
    path = tmp_path("cronvar-absent-noop.txt")
    File.write(path, "SHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.should be_false
  end

  it "leaves crontab schedule lines in the file untouched" do
    path = tmp_path("cronvar-schedule.txt")
    File.write(path, "SHELL=/bin/sh\n#Ansible: nightly backup\n0 2 * * * /bin/backup\n")

    PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    content = File.read(path)
    content.should contain("#Ansible: nightly backup")
    content.should contain("0 2 * * * /bin/backup")
    content.should contain("MAILTO=root")
  end

  it "returns the current variable list in vars" do
    path = tmp_path("cronvar-vars.txt")
    File.write(path, "SHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result["vars"].as_a.map(&.as_s).should eq(["MAILTO", "SHELL"])
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

    result["changed"].as_bool.should be_true
    lines = File.read(path).split("\n")
    lines.index("SHELL=/bin/sh").should eq(0)
    lines.index("PATH=/usr/local/bin").should eq(1)
  end

  it "does not write to disk in check mode" do
    path = tmp_path("cronvar-check-mode.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cronvar", {
      "name"       => "MAILTO",
      "value"      => "root",
      "cron_file"  => path,
      "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.exists?(path).should be_false
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

    result["changed"].as_bool.should be_true
    backup_file = result["backup_file"].as_s
    File.exists?(backup_file).should be_true
    File.read(backup_file).should eq("MAILTO=root\n")
  end

  it "fails with the real module's message when value is missing for state=present" do
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "cron_file" => tmp_path("cronvar-missing-value.txt"),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("You must specify 'value' to insert a new cron variable")
  end

  it "fails when insertbefore and insertafter are both given" do
    result = PluginSpecHelper.run("cronvar", {
      "name"         => "MAILTO",
      "value"        => "root",
      "cron_file"    => tmp_path("cronvar-mutually-exclusive.txt"),
      "insertafter"  => "SHELL",
      "insertbefore" => "SHELL",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("mutually exclusive")
  end
end

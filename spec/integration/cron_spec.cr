require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "cron plugin" do
  it "creates the cron_file and adds a marked entry" do
    path = tmp_path("cron-create.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cron", {
      "name"      => "nightly backup",
      "job"       => "/usr/local/bin/backup.sh",
      "hour"      => "2",
      "minute"    => "0",
      "cron_file" => path,
    })

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("#Ansible: nightly backup")
    content.should contain("0 2 * * * /usr/local/bin/backup.sh")
  end

  it "resolves a relative cron_file: against /etc/cron.d, matching real Ansible" do
    # This spec runs unprivileged, so it can't actually write to
    # /etc/cron.d - it only asserts the path RESOLUTION is correct
    # (cron.py's CronTab#__init__: a relative cron_file: joins onto
    # /etc/cron.d, only an absolute path is used as-is). A permission
    # error at exactly the resolved path is the observable proof.
    result = PluginSpecHelper.run("cron", {
      "name"      => "run lynis",
      "job"       => "/tmp/lynis/lynis --cronjob audit system",
      "hour"      => "4",
      "minute"    => "23",
      "cron_file" => "crystal-ansible-spec-relative",
    })

    result["failed"]?.try(&.as_bool).should be_true
    result["msg"].as_s.should contain("/etc/cron.d/crystal-ansible-spec-relative")
  end

  it "is idempotent on a second run with the same parameters" do
    path = tmp_path("cron-idempotent.txt")
    File.delete(path) if File.exists?(path)
    params = {
      "name"      => "idempotent job",
      "job"       => "/bin/true",
      "cron_file" => path,
    }

    first = PluginSpecHelper.run("cron", params)
    first["changed"].as_bool.should be_true

    second = PluginSpecHelper.run("cron", params)
    second["changed"].as_bool.should be_false
  end

  it "updates the schedule in place when it changes" do
    path = tmp_path("cron-update.txt")
    PluginSpecHelper.run("cron", {"name" => "job", "job" => "/bin/true", "hour" => "1", "cron_file" => path})

    result = PluginSpecHelper.run("cron", {"name" => "job", "job" => "/bin/true", "hour" => "5", "cron_file" => path})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("* 5 * * * /bin/true")
    content.should_not contain("* 1 * * * /bin/true")
  end

  it "removes the entry when state=absent" do
    path = tmp_path("cron-remove.txt")
    PluginSpecHelper.run("cron", {"name" => "to remove", "job" => "/bin/true", "cron_file" => path})

    result = PluginSpecHelper.run("cron", {"name" => "to remove", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.should be_true
    File.read(path).should_not contain("to remove")
  end

  it "leaves other entries in the file untouched" do
    path = tmp_path("cron-multi.txt")
    PluginSpecHelper.run("cron", {"name" => "a", "job" => "/bin/a", "cron_file" => path})
    PluginSpecHelper.run("cron", {"name" => "b", "job" => "/bin/b", "cron_file" => path})

    PluginSpecHelper.run("cron", {"name" => "a", "state" => "absent", "cron_file" => path})

    content = File.read(path)
    content.should_not contain("#Ansible: a")
    content.should contain("#Ansible: b")
    content.should contain("/bin/b")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("cron-check-mode.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cron", {
      "name"       => "would add",
      "job"        => "/bin/true",
      "cron_file"  => path,
      "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.exists?(path).should be_false
  end

  it "supports special_time as a shorthand for the schedule fields" do
    path = tmp_path("cron-special-time.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cron", {
      "name"         => "on reboot",
      "job"          => "/bin/true",
      "special_time" => "reboot",
      "cron_file"    => path,
    })

    result["changed"].as_bool.should be_true
    File.read(path).should contain("@reboot /bin/true")
  end

  it "fails with a clear message when job is missing for state=present" do
    result = PluginSpecHelper.run("cron", {
      "name"      => "no job",
      "cron_file" => tmp_path("cron-missing-job.txt"),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("job")
  end
end

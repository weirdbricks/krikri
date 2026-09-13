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
    # Path-resolution proof (cron.py's CronTab#__init__: a relative
    # cron_file: joins onto /etc/cron.d, only an absolute path is used
    # as-is). The observable evidence depends on privilege:
    # unprivileged, a permission error at exactly the resolved path;
    # as root (CI's job container), the file is actually created there.
    result = PluginSpecHelper.run("cron", {
      "name"      => "run lynis",
      "job"       => "/tmp/lynis/lynis --cronjob audit system",
      "hour"      => "4",
      "minute"    => "23",
      "cron_file" => "krikri-playbook-spec-relative",
    })

    resolved = "/etc/cron.d/krikri-playbook-spec-relative"
    if File.writable?("/etc/cron.d")
      # failed is a JSON::Any - normalize via as_bool (a JSON::Any(false)
      # is not == false for the be_falsey matcher)
      result["failed"]?.try(&.as_bool).should be_false
      File.read(resolved).should contain("/tmp/lynis/lynis")
      File.delete(resolved)
    else
      result["failed"]?.try(&.as_bool).should be_true
      result["msg"].as_s.should contain(resolved)
    end
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

  describe "env: yes" do
    it "writes a NAME=\"value\" line at the top of the file" do
      path = tmp_path("cron-env-create.txt")
      File.write(path, "MAILTO=root\n")
      PluginSpecHelper.run("cron", {"name" => "OLD_JOB", "job" => "/bin/old", "cron_file" => path})

      result = PluginSpecHelper.run("cron", {
        "name"      => "PATH",
        "env"       => "true",
        "job"       => "/opt/bin",
        "cron_file" => path,
      })

      result["changed"].as_bool.should be_true
      content = File.read(path)
      content.should start_with("PATH=\"/opt/bin\"\n")
      content.should contain("MAILTO=root")
      content.should_not contain("#Ansible: PATH")
      content.should contain("#Ansible: OLD_JOB")
    end

    it "is idempotent on a second identical env run" do
      path = tmp_path("cron-env-idempotent.txt")
      params = {"name" => "PATH", "env" => "true", "job" => "/opt/bin", "cron_file" => path}

      PluginSpecHelper.run("cron", params)
      second = PluginSpecHelper.run("cron", params)

      second["changed"].as_bool.should be_false
      File.read(path).should eq("PATH=\"/opt/bin\"\n")
    end

    it "updates the value in place when it changes" do
      path = tmp_path("cron-env-update.txt")
      PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "job" => "/opt/bin", "cron_file" => path})

      result = PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "job" => "/usr/bin", "cron_file" => path})

      result["changed"].as_bool.should be_true
      File.read(path).should eq("PATH=\"/usr/bin\"\n")
    end

    it "removes the variable when state=absent" do
      path = tmp_path("cron-env-absent.txt")
      PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "job" => "/opt/bin", "cron_file" => path})

      result = PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "state" => "absent", "cron_file" => path})

      result["changed"].as_bool.should be_true
      File.read(path).should_not contain("PATH=")
    end

    it "inserts after the named variable with insertafter" do
      path = tmp_path("cron-env-insertafter.txt")
      File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

      PluginSpecHelper.run("cron", {
        "name"        => "PATH",
        "env"         => "true",
        "job"         => "/opt/bin",
        "insertafter" => "MAILTO",
        "cron_file"   => path,
      })

      File.read(path).should eq("MAILTO=root\nPATH=\"/opt/bin\"\nSHELL=/bin/sh\n")
    end

    it "inserts before the named variable with insertbefore" do
      path = tmp_path("cron-env-insertbefore.txt")
      File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

      PluginSpecHelper.run("cron", {
        "name"         => "PATH",
        "env"          => "true",
        "job"          => "/opt/bin",
        "insertbefore" => "SHELL",
        "cron_file"    => path,
      })

      File.read(path).should eq("MAILTO=root\nPATH=\"/opt/bin\"\nSHELL=/bin/sh\n")
    end

    it "fails hard when the insert target variable doesn't exist, leaving the file untouched" do
      path = tmp_path("cron-env-insert-missing.txt")
      File.write(path, "MAILTO=root\n")

      result = PluginSpecHelper.run("cron", {
        "name"        => "PATH",
        "env"         => "true",
        "job"         => "/opt/bin",
        "insertafter" => "NOPE",
        "cron_file"   => path,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Variable named 'NOPE' not found")
      File.read(path).should eq("MAILTO=root\n")
    end

    it "fails when a new env variable's name contains a space" do
      result = PluginSpecHelper.run("cron", {
        "name"      => "MY VAR",
        "env"       => "true",
        "job"       => "/opt/bin",
        "cron_file" => tmp_path("cron-env-space-name.txt"),
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Invalid name for environment variable")
    end
  end

  describe "insertafter/insertbefore without env" do
    it "fails with real Ansible's env-only validation message" do
      path = tmp_path("cron-insert-without-env.txt")

      result = PluginSpecHelper.run("cron", {
        "name"        => "a job",
        "job"         => "/bin/true",
        "insertafter" => "something",
        "cron_file"   => path,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("valid only with env=yes")
    end

    it "fails with real Ansible's mutual-exclusion message when both are given" do
      result = PluginSpecHelper.run("cron", {
        "name"         => "PATH",
        "env"          => "true",
        "job"          => "/opt/bin",
        "insertafter"  => "MAILTO",
        "insertbefore" => "SHELL",
        "cron_file"    => tmp_path("cron-insert-both.txt"),
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("parameters are mutually exclusive: insertafter|insertbefore")
    end
  end

  describe "backup" do
    it "writes a /tmp/crontabXXXXXXXX backup of the original content and reports backup_file" do
      path = tmp_path("cron-backup.txt")
      File.write(path, "MAILTO=root\n")
      before = Dir.glob("/tmp/crontab*").size

      result = PluginSpecHelper.run("cron", {
        "name"      => "a job",
        "job"       => "/bin/true",
        "backup"    => "true",
        "cron_file" => path,
      })

      result["changed"].as_bool.should be_true
      backup_file = result["backup_file"].as_s
      backup_file.should match(%r{/tmp/crontab[a-z0-9_]{8}})
      File.read(backup_file).should eq("MAILTO=root\n")
      (Dir.glob("/tmp/crontab*").size - before).should eq(1)
      File.delete(backup_file)
    end

    it "reports no backup_file and leaves none behind when nothing changed" do
      path = tmp_path("cron-backup-noop.txt")
      PluginSpecHelper.run("cron", {"name" => "a job", "job" => "/bin/true", "cron_file" => path})
      before = Dir.glob("/tmp/crontab*").size

      result = PluginSpecHelper.run("cron", {
        "name"      => "a job",
        "job"       => "/bin/true",
        "backup"    => "true",
        "cron_file" => path,
      })

      result["changed"].as_bool.should be_false
      result["backup_file"]?.should be_nil
      (Dir.glob("/tmp/crontab*").size - before).should eq(0)
    end

    it "takes no backup in check mode and writes nothing" do
      path = tmp_path("cron-backup-check.txt")
      File.write(path, "MAILTO=root\n")
      before = Dir.glob("/tmp/crontab*").size

      result = PluginSpecHelper.run("cron", {
        "name"       => "a job",
        "job"        => "/bin/true",
        "backup"     => "true",
        "check_mode" => "true",
        "cron_file"  => path,
      })

      result["changed"].as_bool.should be_true
      result["backup_file"]?.should be_nil
      (Dir.glob("/tmp/crontab*").size - before).should eq(0)
      File.read(path).should eq("MAILTO=root\n")
    end

    it "backs up the env variant too" do
      path = tmp_path("cron-backup-env.txt")
      File.write(path, "PATH=/opt/bin\n")

      result = PluginSpecHelper.run("cron", {
        "name"      => "PATH",
        "env"       => "true",
        "job"       => "/usr/bin",
        "backup"    => "true",
        "cron_file" => path,
      })

      backup_file = result["backup_file"].as_s
      File.read(backup_file).should eq("PATH=/opt/bin\n")
      File.delete(backup_file)
    end
  end
end

require "../minitest_helper"
require "set"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "cron plugin" do
  it "creates the cron_file and adds a marked entry" do
    path = tmp_path("cron-create.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cron", {
      "name" => "nightly backup",
      "job" => "/usr/local/bin/backup.sh",
      "hour" => "2",
      "minute" => "0",
      "cron_file" => path, "user" => "root",
    })

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("#Ansible: nightly backup")
    content.must_include("0 2 * * * root /usr/local/bin/backup.sh")
  end

  it "resolves a relative cron_file: against /etc/cron.d, matching real Ansible" do
    # Path-resolution proof (cron.py's CronTab#__init__: a relative
    # cron_file: joins onto /etc/cron.d, only an absolute path is used
    # as-is). The observable evidence depends on privilege:
    # unprivileged, a permission error at exactly the resolved path;
    # as root (CI's job container), the file is actually created there.
    result = PluginSpecHelper.run("cron", {
      "name" => "run lynis",
      "job" => "/tmp/lynis/lynis --cronjob audit system",
      "hour" => "4",
      "minute" => "23",
      "cron_file" => "krikri-playbook-spec-relative", "user" => "root",
    })

    resolved = "/etc/cron.d/krikri-playbook-spec-relative"
    if File.writable?("/etc/cron.d")
      # failed is a JSON::Any - normalize via as_bool, and use be_falsey:
      # a JSON::Any(false) is not == false for the matcher, and a SUCCESS
      # result omits the failed key entirely (nil) - the path that runs
      # on a root CI container where /etc/cron.d is writable.
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.read(resolved).must_include("/tmp/lynis/lynis")
      File.delete(resolved)
    else
      result["failed"]?.try(&.as_bool).must_equal(true)
      result["msg"].as_s.must_include(resolved)
    end
  end

  it "is idempotent on a second run with the same parameters" do
    path = tmp_path("cron-idempotent.txt")
    File.delete(path) if File.exists?(path)
    params = {
      "name" => "idempotent job",
      "job" => "/bin/true",
      "cron_file" => path, "user" => "root",
    }

    first = PluginSpecHelper.run("cron", params)
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("cron", params)
    second["changed"].as_bool.must_equal(false)
  end

  it "updates the schedule in place when it changes" do
    path = tmp_path("cron-update.txt")
    PluginSpecHelper.run("cron", {"name" => "job", "job" => "/bin/true", "hour" => "1", "cron_file" => path, "user" => "root"})

    result = PluginSpecHelper.run("cron", {"name" => "job", "job" => "/bin/true", "hour" => "5", "cron_file" => path, "user" => "root"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("* 5 * * * root /bin/true")
    content.wont_include("* 1 * * * /bin/true")
  end

  it "removes the entry when state=absent" do
    path = tmp_path("cron-remove.txt")
    PluginSpecHelper.run("cron", {"name" => "to remove", "job" => "/bin/true", "cron_file" => path, "user" => "root"})

    result = PluginSpecHelper.run("cron", {"name" => "to remove", "state" => "absent", "cron_file" => path, "user" => "root"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).wont_include("to remove")
  end

  it "leaves other entries in the file untouched" do
    path = tmp_path("cron-multi.txt")
    PluginSpecHelper.run("cron", {"name" => "a", "job" => "/bin/a", "cron_file" => path, "user" => "root"})
    PluginSpecHelper.run("cron", {"name" => "b", "job" => "/bin/b", "cron_file" => path, "user" => "root"})

    PluginSpecHelper.run("cron", {"name" => "a", "state" => "absent", "cron_file" => path, "user" => "root"})

    content = File.read(path)
    content.wont_include("#Ansible: a")
    content.must_include("#Ansible: b")
    content.must_include("/bin/b")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("cron-check-mode.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cron", {
      "name" => "would add",
      "job" => "/bin/true",
      "cron_file" => path, "user" => "root",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(false)
  end

  it "supports special_time as a shorthand for the schedule fields" do
    path = tmp_path("cron-special-time.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cron", {
      "name" => "on reboot",
      "job" => "/bin/true",
      "special_time" => "reboot",
      "cron_file" => path, "user" => "root",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_include("@reboot root /bin/true")
  end

  it "fails with a clear message when job is missing for state=present" do
    result = PluginSpecHelper.run("cron", {
      "name" => "no job",
      "cron_file" => tmp_path("cron-missing-job.txt"), "user" => "root",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("job")
  end

  describe "env: yes" do
    it "writes a NAME=\"value\" line at the top of the file" do
      path = tmp_path("cron-env-create.txt")
      File.write(path, "MAILTO=root\n")
      PluginSpecHelper.run("cron", {"name" => "OLD_JOB", "job" => "/bin/old", "cron_file" => path, "user" => "root"})

      result = PluginSpecHelper.run("cron", {
        "name" => "PATH",
        "env" => "true",
        "job" => "/opt/bin",
        "cron_file" => path, "user" => "root",
      })

      result["changed"].as_bool.must_equal(true)
      content = File.read(path)
      expect(content.starts_with?("PATH=\"/opt/bin\"\n")).must_equal(true)
      content.must_include("MAILTO=root")
      content.wont_include("#Ansible: PATH")
      content.must_include("#Ansible: OLD_JOB")
    end

    it "is idempotent on a second identical env run" do
      path = tmp_path("cron-env-idempotent.txt")
      params = {"name" => "PATH", "env" => "true", "job" => "/opt/bin", "cron_file" => path, "user" => "root"}

      PluginSpecHelper.run("cron", params)
      second = PluginSpecHelper.run("cron", params)

      second["changed"].as_bool.must_equal(false)
      File.read(path).must_equal("PATH=\"/opt/bin\"\n")
    end

    it "updates the value in place when it changes" do
      path = tmp_path("cron-env-update.txt")
      PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "job" => "/opt/bin", "cron_file" => path, "user" => "root"})

      result = PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "job" => "/usr/bin", "cron_file" => path, "user" => "root"})

      result["changed"].as_bool.must_equal(true)
      File.read(path).must_equal("PATH=\"/usr/bin\"\n")
    end

    it "removes the variable when state=absent" do
      path = tmp_path("cron-env-absent.txt")
      PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "job" => "/opt/bin", "cron_file" => path, "user" => "root"})

      result = PluginSpecHelper.run("cron", {"name" => "PATH", "env" => "true", "state" => "absent", "cron_file" => path, "user" => "root"})

      result["changed"].as_bool.must_equal(true)
      File.read(path).wont_include("PATH=")
    end

    # Real bug, round 811204 (infOpen.lynis): the role manages crontab
    # vars with `value:` - cron.py's documented alias of `job` - and
    # real ansible-playbook accepts it, but an unresolved alias left
    # `job` nil and the task failed with "job parameter required when
    # state=present". These mirror the role's exact task shape.
    describe "`value:` alias (cron.py's aliases: ['value'])" do
      it "creates an env-var line from value:" do
        path = tmp_path("cron-env-alias-create.txt")
        File.delete(path) if File.exists?(path)

        result = PluginSpecHelper.run("cron", {
          "name"      => "CURRENT_DATE",
          "env"       => "true",
          "value"     => "date +%Y%m%d",
          "user"      => "root",
          "cron_file" => path,
        })

        falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
        result["changed"].as_bool.must_equal(true)
        File.read(path).must_include("CURRENT_DATE=\"date +%Y%m%d\"")
      end

      it "is idempotent on a second identical value: run" do
        path = tmp_path("cron-env-alias-idempotent.txt")
        params = {"name" => "CURRENT_DATE", "env" => "true", "value" => "date +%Y%m%d", "user" => "root", "cron_file" => path}

        PluginSpecHelper.run("cron", params)
        second = PluginSpecHelper.run("cron", params)

        second["changed"].as_bool.must_equal(false)
        File.read(path).must_equal("CURRENT_DATE=\"date +%Y%m%d\"\n")
      end

      it "removes the alias-defined variable when state=absent" do
        path = tmp_path("cron-env-alias-absent.txt")
        PluginSpecHelper.run("cron", {"name" => "CURRENT_DATE", "env" => "true", "value" => "date +%Y%m%d", "cron_file" => path, "user" => "root"})

        result = PluginSpecHelper.run("cron", {"name" => "CURRENT_DATE", "env" => "true", "value" => "date +%Y%m%d", "state" => "absent", "cron_file" => path, "user" => "root"})

        result["changed"].as_bool.must_equal(true)
        File.read(path).wont_include("CURRENT_DATE=")
      end

      it "honors value: on the plain-job path too (it aliases job)" do
        path = tmp_path("cron-job-alias.txt")
        File.delete(path) if File.exists?(path)

        result = PluginSpecHelper.run("cron", {
          "name" => "aliased job",
          "value" => "/bin/true",
          "cron_file" => path, "user" => "root",
        })

        result["changed"].as_bool.must_equal(true)
        File.read(path).must_include("* * * * * root /bin/true")
      end
    end

    it "inserts after the named variable with insertafter" do
      path = tmp_path("cron-env-insertafter.txt")
      File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

      PluginSpecHelper.run("cron", {
        "name" => "PATH",
        "env" => "true",
        "job" => "/opt/bin",
        "insertafter" => "MAILTO",
        "cron_file" => path, "user" => "root",
      })

      File.read(path).must_equal("MAILTO=root\nPATH=\"/opt/bin\"\nSHELL=/bin/sh\n")
    end

    it "inserts before the named variable with insertbefore" do
      path = tmp_path("cron-env-insertbefore.txt")
      File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

      PluginSpecHelper.run("cron", {
        "name" => "PATH",
        "env" => "true",
        "job" => "/opt/bin",
        "insertbefore" => "SHELL",
        "cron_file" => path, "user" => "root",
      })

      File.read(path).must_equal("MAILTO=root\nPATH=\"/opt/bin\"\nSHELL=/bin/sh\n")
    end

    it "fails hard when the insert target variable doesn't exist, leaving the file untouched" do
      path = tmp_path("cron-env-insert-missing.txt")
      File.write(path, "MAILTO=root\n")

      result = PluginSpecHelper.run("cron", {
        "name" => "PATH",
        "env" => "true",
        "job" => "/opt/bin",
        "insertafter" => "NOPE",
        "cron_file" => path, "user" => "root",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("Variable named 'NOPE' not found")
      File.read(path).must_equal("MAILTO=root\n")
    end

    it "fails when a new env variable's name contains a space" do
      result = PluginSpecHelper.run("cron", {
        "name" => "MY VAR",
        "env" => "true",
        "job" => "/opt/bin",
        "cron_file" => tmp_path("cron-env-space-name.txt"), "user" => "root",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("Invalid name for environment variable")
    end
  end

  describe "insertafter/insertbefore without env" do
    it "fails with real Ansible's env-only validation message" do
      path = tmp_path("cron-insert-without-env.txt")

      result = PluginSpecHelper.run("cron", {
        "name" => "a job",
        "job" => "/bin/true",
        "insertafter" => "something",
        "cron_file" => path, "user" => "root",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("valid only with env=yes")
    end

    it "fails with real Ansible's mutual-exclusion message when both are given" do
      result = PluginSpecHelper.run("cron", {
        "name" => "PATH",
        "env" => "true",
        "job" => "/opt/bin",
        "insertafter" => "MAILTO",
        "insertbefore" => "SHELL",
        "cron_file" => tmp_path("cron-insert-both.txt"), "user" => "root",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("parameters are mutually exclusive: insertafter|insertbefore")
    end
  end

  # The cron plugin's real backups land in the FIXED /tmp/crontab*
  # namespace (real crontab's own convention, not a tmp_path-able path),
  # and these three specs count glob deltas - under minitest's parallel
  # workers they would see each other's backups, so they serialize on
  # STATE_MUTEX.
  describe "backup" do
    # /tmp/crontab* is host-wide: any other process running this suite
    # (or real crontab) adds files there between a test's before/after
    # globs. So each test's crontab carries a unique marker, and only new
    # backups containing that marker count.
    private def new_backups_with(before : Set(String), marker : String) : Set(String)
      (Dir.glob("/tmp/crontab*").to_set - before).select { |f| (File.read(f) rescue "").includes?(marker) }.to_set
    end

    it "writes a /tmp/crontabXXXXXXXX backup of the original content and reports backup_file" do
      PluginSpecHelper::STATE_MUTEX.synchronize do
        path = tmp_path("cron-backup.txt")
        marker = "# krikri-cron-backup #{Random::Secure.hex(8)}"
        original = "MAILTO=root\n#{marker}\n"
        File.write(path, original)
        before = Dir.glob("/tmp/crontab*").to_set

        result = PluginSpecHelper.run("cron", {
          "name" => "a job",
          "job" => "/bin/true",
          "backup" => "true",
          "cron_file" => path, "user" => "root",
        })

        result["changed"].as_bool.must_equal(true)
        backup_file = result["backup_file"].as_s
        backup_file.must_match(%r{/tmp/crontab[a-z0-9_]{8}})
        File.read(backup_file).must_equal(original)
        new_backups_with(before, marker).must_equal([backup_file].to_set)
        File.delete(backup_file)
      end
    end

    it "reports no backup_file and leaves none behind when nothing changed" do
      PluginSpecHelper::STATE_MUTEX.synchronize do
        path = tmp_path("cron-backup-noop.txt")
        marker = "# krikri-cron-backup-noop #{Random::Secure.hex(8)}"
        File.write(path, "#{marker}\n")
        PluginSpecHelper.run("cron", {"name" => "a job", "job" => "/bin/true", "cron_file" => path, "user" => "root"})
        before = Dir.glob("/tmp/crontab*").to_set

        result = PluginSpecHelper.run("cron", {
          "name" => "a job",
          "job" => "/bin/true",
          "backup" => "true",
          "cron_file" => path, "user" => "root",
        })

        result["changed"].as_bool.must_equal(false)
        result["backup_file"]?.must_be_nil
        new_backups_with(before, marker).must_be_empty
      end
    end

    it "takes no backup in check mode and writes nothing" do
      PluginSpecHelper::STATE_MUTEX.synchronize do
        path = tmp_path("cron-backup-check.txt")
        marker = "# krikri-cron-backup-check #{Random::Secure.hex(8)}"
        original = "MAILTO=root\n#{marker}\n"
        File.write(path, original)
        before = Dir.glob("/tmp/crontab*").to_set

        result = PluginSpecHelper.run("cron", {
          "name" => "a job",
          "job" => "/bin/true",
          "backup" => "true",
          "_ansible_check_mode" => "true",
          "cron_file" => path, "user" => "root",
        })

        result["changed"].as_bool.must_equal(true)
        result["backup_file"]?.must_be_nil
        new_backups_with(before, marker).must_be_empty
        File.read(path).must_equal(original)
      end
    end

    it "backs up the env variant too" do
      path = tmp_path("cron-backup-env.txt")
      File.write(path, "PATH=/opt/bin\n")

      result = PluginSpecHelper.run("cron", {
        "name" => "PATH",
        "env" => "true",
        "job" => "/usr/bin",
        "backup" => "true",
        "cron_file" => path, "user" => "root",
      })

      backup_file = result["backup_file"].as_s
      File.read(backup_file).must_equal("PATH=/opt/bin\n")
      File.delete(backup_file)
    end
  end

  # Real cron.py's result carries `jobs`/`envs` - the FULL current list
  # of every marked job / env assignment in the crontab after the
  # operation, not just the one entry the task touched (live-verified
  # against ansible-core 2.19.11).
  describe "jobs/envs result fields (real ansible's full post-op lists)" do
    it "reports all current job names and env names after an add" do
      path = tmp_path("cron-fields.txt")
      File.delete(path) if File.exists?(path)

      PluginSpecHelper.run("cron", {"name" => "first job", "job" => "/bin/true", "cron_file" => path, "user" => "root"})
      result = PluginSpecHelper.run("cron", {"name" => "second job", "job" => "/bin/ls", "cron_file" => path, "user" => "root"})

      result["jobs"].as_a.map(&.as_s).must_equal(["first job", "second job"])
      result["envs"].as_a.must_be_empty
    end

    it "reports env names on the env: true path and keeps job names in sync" do
      path = tmp_path("cron-fields-env.txt")
      File.delete(path) if File.exists?(path)

      PluginSpecHelper.run("cron", {"name" => "a job", "job" => "/bin/true", "cron_file" => path, "user" => "root"})
      result = PluginSpecHelper.run("cron", {"name" => "MAILTO", "env" => "true", "job" => "root", "cron_file" => path, "user" => "root"})

      result["envs"].as_a.map(&.as_s).must_equal(["MAILTO"])
      result["jobs"].as_a.map(&.as_s).must_equal(["a job"])
    end

    it "updates the lists on state: absent" do
      path = tmp_path("cron-fields-absent.txt")
      File.write(path, "#Ansible: gone job\n* * * * * /bin/true\n#Ansible: stays\n1 1 1 1 1 /bin/ls\n")

      result = PluginSpecHelper.run("cron", {"name" => "gone job", "state" => "absent", "cron_file" => path, "user" => "root"})

      result["changed"].as_bool.must_equal(true)
      result["jobs"].as_a.map(&.as_s).must_equal(["stays"])
    end

    it "carries the full lists on a no-op second run too (real ansible exits with them every time)" do
      path = tmp_path("cron-fields-noop.txt")
      params = {"name" => "a job", "job" => "/bin/true", "cron_file" => path, "user" => "root"}
      PluginSpecHelper.run("cron", params)

      result = PluginSpecHelper.run("cron", params)

      result["changed"].as_bool.must_equal(false)
      result["jobs"].as_a.map(&.as_s).must_equal(["a job"])
    end

    it "reports an empty job list for a crontab with no marked entries" do
      path = tmp_path("cron-fields-empty.txt")
      File.write(path, "MAILTO=root\n* * * * * /bin/true\n")

      result = PluginSpecHelper.run("cron", {"name" => "brand new", "job" => "/bin/true", "cron_file" => path, "user" => "root"})

      result["jobs"].as_a.map(&.as_s).must_equal(["brand new"])
      result["envs"].as_a.map(&.as_s).must_equal(["MAILTO"])
    end
  end
end

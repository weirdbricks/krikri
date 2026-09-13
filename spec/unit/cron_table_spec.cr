require "../spec_helper"
require "../../src/krikri/plugin_helpers/cron_table"

private alias CronTable = Krikri::PluginHelpers::CronTable

describe CronTable do
  describe ".schedule" do
    it "joins the five fields" do
      CronTable.schedule("1", "2", "3", "4", "5", nil).should eq("1 2 3 4 5")
    end

    it "prefers special_time over the individual fields" do
      CronTable.schedule("*", "*", "*", "*", "*", "reboot").should eq("@reboot")
    end
  end

  describe ".render_line" do
    it "renders schedule + job without a user field" do
      CronTable.render_line("* * * * *", "/bin/true", nil, false).should eq("* * * * * /bin/true")
    end

    it "includes the user field when given (cron.d style)" do
      CronTable.render_line("* * * * *", "/bin/true", "root", false).should eq("* * * * * root /bin/true")
    end

    it "comments the line out when disabled" do
      CronTable.render_line("* * * * *", "/bin/true", nil, true).should eq("#* * * * * /bin/true")
    end
  end

  describe ".upsert" do
    it "appends a new marker+entry block to empty text" do
      text, changed = CronTable.upsert("", "backup", "0 2 * * * /bin/backup")
      text.should eq("#Ansible: backup\n0 2 * * * /bin/backup\n")
      changed.should be_true
    end

    it "appends after existing unrelated content" do
      text, changed = CronTable.upsert("0 1 * * * /bin/other\n", "backup", "0 2 * * * /bin/backup")
      text.should eq("0 1 * * * /bin/other\n#Ansible: backup\n0 2 * * * /bin/backup\n")
      changed.should be_true
    end

    it "is idempotent when the exact same block is already present" do
      _, changed = CronTable.upsert("#Ansible: backup\n0 2 * * * /bin/backup\n", "backup", "0 2 * * * /bin/backup")
      changed.should be_false
    end

    it "replaces the entry in place when the schedule/job changes" do
      original = "#Ansible: other\n* * * * * /bin/other\n#Ansible: backup\n0 2 * * * /bin/backup\n"
      text, changed = CronTable.upsert(original, "backup", "0 3 * * * /bin/backup")

      text.should eq("#Ansible: other\n* * * * * /bin/other\n#Ansible: backup\n0 3 * * * /bin/backup\n")
      changed.should be_true
    end

    it "removes the block when new_line is nil (state: absent)" do
      original = "#Ansible: other\n* * * * * /bin/other\n#Ansible: backup\n0 2 * * * /bin/backup\n"
      text, changed = CronTable.upsert(original, "backup", nil)

      text.should eq("#Ansible: other\n* * * * * /bin/other\n")
      changed.should be_true
    end

    it "is a no-op removing an entry that was never there" do
      original = "#Ansible: other\n* * * * * /bin/other\n"
      text, changed = CronTable.upsert(original, "backup", nil)

      text.should eq(original)
      changed.should be_false
    end

    it "leaves other entries untouched" do
      original = "#Ansible: a\n* * * * * /bin/a\n#Ansible: b\n* * * * * /bin/b\n#Ansible: c\n* * * * * /bin/c\n"
      text, changed = CronTable.upsert(original, "b", "*/5 * * * * /bin/b")

      text.should contain("#Ansible: a\n* * * * * /bin/a")
      text.should contain("#Ansible: b\n*/5 * * * * /bin/b")
      text.should contain("#Ansible: c\n* * * * * /bin/c")
      changed.should be_true
    end
  end

  describe ".marker" do
    it "renders a stable, greppable comment for a given name" do
      CronTable.marker("nightly backup").should eq("#Ansible: nightly backup")
    end
  end

  describe ".env_decl" do
    it "always double-quotes the value (real cron.py's decl format)" do
      CronTable.env_decl("PATH", "/opt/bin").should eq("PATH=\"/opt/bin\"")
    end
  end

  describe ".upsert_env" do
    it "inserts a NEW variable at the TOP of the file (real add_env)" do
      text, changed, missing = CronTable.upsert_env("0 1 * * * /bin/other\n", "PATH", "PATH=\"/opt/bin\"", nil, nil)

      text.should eq("PATH=\"/opt/bin\"\n0 1 * * * /bin/other\n")
      changed.should be_true
      missing.should be_nil
    end

    it "inserts immediately after the named variable with insertafter" do
      original = "MAILTO=root\nSHELL=/bin/sh\n0 1 * * * /bin/other\n"
      text, changed, missing = CronTable.upsert_env(original, "PATH", "PATH=\"/opt/bin\"", "MAILTO", nil)

      text.should eq("MAILTO=root\nPATH=\"/opt/bin\"\nSHELL=/bin/sh\n0 1 * * * /bin/other\n")
      changed.should be_true
      missing.should be_nil
    end

    it "inserts immediately before the named variable with insertbefore" do
      original = "MAILTO=root\nSHELL=/bin/sh\n"
      text, _, missing = CronTable.upsert_env(original, "PATH", "PATH=\"/opt/bin\"", nil, "SHELL")

      text.should eq("MAILTO=root\nPATH=\"/opt/bin\"\nSHELL=/bin/sh\n")
      missing.should be_nil
    end

    it "fails without writing when the insert target variable doesn't exist" do
      original = "MAILTO=root\n"
      text, changed, missing = CronTable.upsert_env(original, "PATH", "PATH=\"/opt/bin\"", "NOPE", nil)

      text.should eq(original)
      changed.should be_false
      missing.should eq("NOPE")
    end

    it "is idempotent when the identical decl is already present" do
      _, changed, missing = CronTable.upsert_env("PATH=\"/opt/bin\"\n", "PATH", "PATH=\"/opt/bin\"", nil, nil)

      changed.should be_false
      missing.should be_nil
    end

    it "replaces the assignment in place when the value changes" do
      original = "PATH=\"/opt/bin\"\nMAILTO=root\n"
      text, changed, _ = CronTable.upsert_env(original, "PATH", "PATH=\"/usr/bin\"", nil, nil)

      text.should eq("PATH=\"/usr/bin\"\nMAILTO=root\n")
      changed.should be_true
    end

    it "replaces every duplicate assignment with the decl (real update_env)" do
      original = "PATH=\"/a\"\nMAILTO=root\nPATH=\"/b\"\n"
      text, changed, _ = CronTable.upsert_env(original, "PATH", "PATH=\"/usr/bin\"", nil, nil)

      text.should eq("PATH=\"/usr/bin\"\nMAILTO=root\nPATH=\"/usr/bin\"\n")
      changed.should be_true
    end

    it "removes the assignment when decl is nil (state: absent)" do
      original = "MAILTO=root\nPATH=\"/opt/bin\"\n0 1 * * * /bin/other\n"
      text, changed, _ = CronTable.upsert_env(original, "PATH", nil, nil, nil)

      text.should eq("MAILTO=root\n0 1 * * * /bin/other\n")
      changed.should be_true
    end

    it "is a no-op removing a variable that was never there" do
      original = "MAILTO=root\n"
      text, changed, _ = CronTable.upsert_env(original, "PATH", nil, nil, nil)

      text.should eq(original)
      changed.should be_false
    end

    it "matches on a strict NAME= line prefix (NAMEX= is not NAME=)" do
      original = "PATHX=/somewhere\n"
      text, changed, _ = CronTable.upsert_env(original, "PATH", "PATH=\"/opt/bin\"", nil, nil)

      text.should eq("PATH=\"/opt/bin\"\nPATHX=/somewhere\n")
      changed.should be_true
    end
  end

  # Real cron.py's get_jobnames/get_envnames - the module result's
  # `jobs`/`envs` fields list EVERY current entry, not just the one the
  # task touched (live-verified against ansible-core 2.19.11).
  describe ".job_names" do
    it "lists every marker-carried job name in file order" do
      text = "MAILTO=root\n#Ansible: nightly backup\n0 2 * * * /usr/local/bin/backup.sh\n#Ansible: other job\n1 2 * * * /bin/true\n"

      CronTable.job_names(text).should eq(["nightly backup", "other job"])
    end

    it "ignores non-marker lines (including bare crontab comments)" do
      text = "# a regular comment\n#Ansible: only job\n* * * * * /bin/true\n"

      CronTable.job_names(text).should eq(["only job"])
    end

    it "returns an empty list for text with no markers" do
      CronTable.job_names("MAILTO=root\n* * * * * /bin/true\n").should eq([] of String)
    end
  end

  describe ".env_names" do
    it "lists every NAME= assignment in file order" do
      text = "MAILTO=root\nPATH=\"/usr/bin:/bin\"\n0 2 * * * /bin/true\n"

      CronTable.env_names(text).should eq(["MAILTO", "PATH"])
    end

    it "counts a commented-out assignment, like real cron.py's ^\\S+= match" do
      text = "#MAILTO=root\nPATH=\"/bin\"\n"

      CronTable.env_names(text).should eq(["#MAILTO", "PATH"])
    end

    it "ignores schedule lines and marker comments" do
      text = "#Ansible: job\n* * * * * FOO=bar\nMAILTO=root\n"

      CronTable.env_names(text).should eq(["MAILTO"])
    end
  end
end

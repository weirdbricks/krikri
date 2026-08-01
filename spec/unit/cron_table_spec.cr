require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/cron_table"

private alias CronTable = CrystalPlay::PluginHelpers::CronTable

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
end

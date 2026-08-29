require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/mysql_privileges"

private alias Grant = CrystalPlay::PluginHelpers::MysqlPrivileges::Grant

describe CrystalPlay::PluginHelpers::MysqlPrivileges do
  describe ".parse_spec" do
    it "parses a single db.table:priv1,priv2 entry" do
      grants = CrystalPlay::PluginHelpers::MysqlPrivileges.parse_spec("testdb.*:SELECT,INSERT")
      grants.should eq([Grant.new("testdb.*", Set{"SELECT", "INSERT"})])
    end

    it "parses multiple grants separated by /" do
      grants = CrystalPlay::PluginHelpers::MysqlPrivileges.parse_spec("db1.*:SELECT/db2.*:ALL")
      grants.should eq([
        Grant.new("db1.*", Set{"SELECT"}),
        Grant.new("db2.*", Set{"ALL"}),
      ])
    end

    it "normalizes ALL PRIVILEGES to ALL" do
      grants = CrystalPlay::PluginHelpers::MysqlPrivileges.parse_spec("db.*:ALL PRIVILEGES")
      grants.should eq([Grant.new("db.*", Set{"ALL"})])
    end

    it "uppercases privilege names" do
      grants = CrystalPlay::PluginHelpers::MysqlPrivileges.parse_spec("db.*:select,insert")
      grants.should eq([Grant.new("db.*", Set{"SELECT", "INSERT"})])
    end

    it "raises on an entry with no : separator" do
      expect_raises(Exception, /invalid priv entry/) do
        CrystalPlay::PluginHelpers::MysqlPrivileges.parse_spec("not-a-valid-entry")
      end
    end
  end

  # Real `SHOW GRANTS FOR user@host` output, captured from a live MariaDB
  # 11 server - see git log's mysql_user commits.
  describe ".parse_show_grants_line" do
    it "returns nil for the baseline GRANT USAGE identity row" do
      line = "GRANT USAGE ON *.* TO `demo4`@`%` IDENTIFIED BY PASSWORD '*14E65567ABDB5135D0CFD9A70B3032C179A49EE7'"
      CrystalPlay::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line).should be_nil
    end

    it "parses ALL PRIVILEGES on a single database" do
      line = "GRANT ALL PRIVILEGES ON `testdb1`.* TO `demo1`@`%`"
      CrystalPlay::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .should eq(Grant.new("testdb1.*", Set{"ALL"}))
    end

    it "parses a comma-separated privilege list" do
      line = "GRANT SELECT, INSERT ON `testdb1`.* TO `demo2`@`%`"
      CrystalPlay::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .should eq(Grant.new("testdb1.*", Set{"SELECT", "INSERT"}))
    end

    it "maps WITH GRANT OPTION to a GRANT pseudo-privilege" do
      line = "GRANT ALL PRIVILEGES ON *.* TO `demo3`@`%` IDENTIFIED BY PASSWORD '*X' WITH GRANT OPTION"
      CrystalPlay::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .should eq(Grant.new("*.*", Set{"ALL", "GRANT"}))
    end

    it "strips backticks from the target" do
      line = "GRANT SELECT ON `testdb2`.* TO `demo2`@`%`"
      (CrystalPlay::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line) || raise "unexpected nil").target.should eq("testdb2.*")
    end

    it "returns nil for a non-GRANT line" do
      CrystalPlay::PluginHelpers::MysqlPrivileges.parse_show_grants_line("Grants for demo1@%").should be_nil
    end
  end

  describe ".current_grants / .desired_grants" do
    it "matches a real multi-database SHOW GRANTS result against the equivalent priv: spec" do
      show_grants = [
        "Grants for demo2@%",
        "GRANT USAGE ON *.* TO `demo2`@`%` IDENTIFIED BY PASSWORD '*14E65567ABDB5135D0CFD9A70B3032C179A49EE7'",
        "GRANT SELECT, INSERT ON `testdb1`.* TO `demo2`@`%`",
        "GRANT SELECT ON `testdb2`.* TO `demo2`@`%`",
      ]

      current = CrystalPlay::PluginHelpers::MysqlPrivileges.current_grants(show_grants)
      desired = CrystalPlay::PluginHelpers::MysqlPrivileges.desired_grants("testdb1.*:SELECT,INSERT/testdb2.*:SELECT")

      current.should eq(desired)
    end

    it "detects a real difference (extra privilege) as unequal" do
      show_grants = ["GRANT SELECT ON `testdb1`.* TO `demo`@`%`"]
      current = CrystalPlay::PluginHelpers::MysqlPrivileges.current_grants(show_grants)
      desired = CrystalPlay::PluginHelpers::MysqlPrivileges.desired_grants("testdb1.*:SELECT,INSERT")

      current.should_not eq(desired)
    end
  end
end

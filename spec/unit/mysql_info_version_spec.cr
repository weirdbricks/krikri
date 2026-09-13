require "../spec_helper"
require "../../src/krikri/plugin_helpers/mysql_info_version"

# Unit-tests mysql_info's version-string parsing against real
# community.mysql.mysql_info's own __get_global_variables algorithm
# (verified against the installed module, 2026-09-13 ad-hoc CLI sweep):
# split the full version string on '.', take release/suffix from the
# THIRD component only, and leave `full` unmodified.
describe Krikri::PluginHelpers::MysqlInfoVersion do
  describe ".parse" do
    it "keeps full unmodified and parses the numeric components" do
      v = Krikri::PluginHelpers::MysqlInfoVersion.parse("10.11.14-MariaDB-0ubuntu0.24.04.1")
      v["full"].as_s.should eq("10.11.14-MariaDB-0ubuntu0.24.04.1")
      v["major"].as_i64.should eq(10)
      v["minor"].as_i64.should eq(11)
      v["release"].as_i64.should eq(14)
      # The real module only ever looks inside the third dot component, so
      # the ".24.04.1" tail lands in components it never reads - the
      # suffix really is "MariaDB-0ubuntu0" there, verified live.
      v["suffix"].as_s.should eq("MariaDB-0ubuntu0")
    end

    it "parses a plain MySQL-style version with an Ubuntu revision suffix" do
      v = Krikri::PluginHelpers::MysqlInfoVersion.parse("8.0.35-0ubuntu0.22.04.1")
      v["full"].as_s.should eq("8.0.35-0ubuntu0.22.04.1")
      v["major"].as_i64.should eq(8)
      v["minor"].as_i64.should eq(0)
      v["release"].as_i64.should eq(35)
      v["suffix"].as_s.should eq("0ubuntu0")
    end

    it "handles the classic 5.5.60-MariaDB shape" do
      v = Krikri::PluginHelpers::MysqlInfoVersion.parse("5.5.60-MariaDB")
      v["full"].as_s.should eq("5.5.60-MariaDB")
      v["major"].as_i64.should eq(5)
      v["minor"].as_i64.should eq(5)
      v["release"].as_i64.should eq(60)
      v["suffix"].as_s.should eq("MariaDB")
    end

    it "leaves the suffix empty when the version is purely numeric" do
      v = Krikri::PluginHelpers::MysqlInfoVersion.parse("8.0.35")
      v["suffix"].as_s.should eq("")
      v["release"].as_i64.should eq(35)
      v["full"].as_s.should eq("8.0.35")
    end

    it "never reports a suffix with a leading dash" do
      # The old krikri behavior picked up "-MariaDB-..." via a
      # partition-on-first-non-numeric, keeping the separator.
      ["10.11.14-MariaDB-0ubuntu0.24.04.1", "8.0.35-0ubuntu0", "5.5.60-MariaDB"].each do |raw|
        Krikri::PluginHelpers::MysqlInfoVersion.parse(raw)["suffix"].as_s.should_not start_with("-")
      end
    end
  end
end

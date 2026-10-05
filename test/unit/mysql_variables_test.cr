require "../minitest_helper"
require "../../src/krikri/plugin_helpers/mysql_variables"

# Unit-tests the mysql_variables logic against real community.mysql
# .mysql_variables' own behavior (typedvalue, convert_bool_setting_value
# _wanted, the variable-name validation, setvariable's backtick quoting).
# Execution talks to a real MySQL/MariaDB server - the value-handling
# and SET-statement shapes don't.
describe Krikri::PluginHelpers::MysqlVariables do
  describe ".valid_name?" do
    it "accepts ordinary variable names with dots" do
      ["datadir", "sync_binlog", "innodb_fast_shutdown", "my.var_1"].each do |name|
        Krikri::PluginHelpers::MysqlVariables.valid_name?(name).must_equal(true)
      end
    end

    it "rejects injection-shaped names like the Ansible module" do
      ["a; DROP TABLE x", "var name", "var'"].each do |name|
        Krikri::PluginHelpers::MysqlVariables.valid_name?(name).must_equal(false)
      end
    end
  end

  describe ".typed_value" do
    it "converts numeric strings to numbers" do
      Krikri::PluginHelpers::MysqlVariables.typed_value("3").must_equal(3i64)
      Krikri::PluginHelpers::MysqlVariables.typed_value("3.0").must_equal(3.0)
    end

    it "keeps non-numeric strings as strings" do
      Krikri::PluginHelpers::MysqlVariables.typed_value("/var/lib/mysql").must_equal("/var/lib/mysql")
    end
  end

  describe ".convert_bool" do
    it "maps 0/1/on/off to ON/OFF" do
      Krikri::PluginHelpers::MysqlVariables.convert_bool("1").must_equal("ON")
      Krikri::PluginHelpers::MysqlVariables.convert_bool("on").must_equal("ON")
      Krikri::PluginHelpers::MysqlVariables.convert_bool("0").must_equal("OFF")
      Krikri::PluginHelpers::MysqlVariables.convert_bool("off").must_equal("OFF")
    end

    it "leaves other values alone" do
      Krikri::PluginHelpers::MysqlVariables.convert_bool("/var/lib/mysql").must_equal("/var/lib/mysql")
    end
  end

  describe ".values_equal?" do
    it "compares numeric strings against numbers" do
      Krikri::PluginHelpers::MysqlVariables.values_equal?(1i64, "1").must_equal(true)
      Krikri::PluginHelpers::MysqlVariables.values_equal?(1i64, "1.0").must_equal(true)
      Krikri::PluginHelpers::MysqlVariables.values_equal?("ON", "ON").must_equal(true)
      Krikri::PluginHelpers::MysqlVariables.values_equal?("1", "0").must_equal(false)
    end

    it "compares plain strings exactly" do
      Krikri::PluginHelpers::MysqlVariables.values_equal?("/var/lib/mysql", "/var/lib/mysql").must_equal(true)
      Krikri::PluginHelpers::MysqlVariables.values_equal?("/var/lib/mysql", "/var/lib/other").must_equal(false)
    end
  end

  describe ".set_statement" do
    it "builds a backtick-quoted SET GLOBAL" do
      Krikri::PluginHelpers::MysqlVariables.set_statement("read_only", 1i64, "global")
        .must_equal("SET GLOBAL `read_only` = 1")
    end

    it "sends ON/OFF as bare literals and strings as quoted literals" do
      Krikri::PluginHelpers::MysqlVariables.set_statement("log_slow_replica_statements", "ON", "global")
        .must_equal("SET GLOBAL `log_slow_replica_statements` = ON")
      Krikri::PluginHelpers::MysqlVariables.set_statement("datadir", "/var/lib/mysql", "global")
        .must_equal("SET GLOBAL `datadir` = '/var/lib/mysql'")
    end

    it "escapes single quotes in string values" do
      Krikri::PluginHelpers::MysqlVariables.set_statement("some_var", "o'brien", "global")
        .must_equal("SET GLOBAL `some_var` = 'o''brien'")
    end

    it "uses PERSIST / PERSIST_ONLY keywords for those modes" do
      Krikri::PluginHelpers::MysqlVariables.set_statement("read_only", 1i64, "persist")
        .must_equal("SET PERSIST `read_only` = 1")
      Krikri::PluginHelpers::MysqlVariables.set_statement("read_only", 1i64, "persist_only")
        .must_equal("SET PERSIST_ONLY `read_only` = 1")
    end
  end
end

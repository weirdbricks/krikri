require "../minitest_helper"
require "../../src/krikri/plugin_helpers/mysql_command_resolver"

# Unit-tests ansible.mysql's CommandResolver table (module_utils/
# command_resolver.py). MariaDB renames SHOW SLAVE HOSTS to SHOW REPLICA
# HOSTS, not to MySQL's SHOW REPLICAS - MariaDB rejects the latter with a
# syntax error, which is what broke a plain mysql_info read on MariaDB.
describe Krikri::PluginHelpers::MysqlCommandResolver do
  describe ".resolve" do
    it "uses MariaDB's SHOW REPLICA HOSTS spelling from 10.5.1 on" do
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE HOSTS", "MariaDB", "10.11.6-MariaDB-0ubuntu0.24.04.1")
        .must_equal("SHOW REPLICA HOSTS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE HOSTS", "MariaDB", "10.5.1-MariaDB")
        .must_equal("SHOW REPLICA HOSTS")
    end

    it "keeps MariaDB's SHOW SLAVE HOSTS below 10.5.1" do
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE HOSTS", "MariaDB", "10.4.34-MariaDB")
        .must_equal("SHOW SLAVE HOSTS")
    end

    it "uses MySQL's SHOW REPLICAS spelling from 8.0.22 on" do
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE HOSTS", "MySQL", "8.4.0")
        .must_equal("SHOW REPLICAS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE HOSTS", "MySQL", "8.0.21")
        .must_equal("SHOW SLAVE HOSTS")
    end

    it "renames SHOW SLAVE STATUS only on the versions that support it" do
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE STATUS", "MariaDB", "10.11.6-MariaDB").must_equal("SHOW REPLICA STATUS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE STATUS", "MySQL", "8.0.22").must_equal("SHOW REPLICA STATUS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW SLAVE STATUS", "MySQL", "8.0.21").must_equal("SHOW SLAVE STATUS")
    end

    it "resolves SHOW MASTER STATUS per implementation and version" do
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW MASTER STATUS", "MySQL", "8.2.0").must_equal("SHOW BINARY LOG STATUS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW MASTER STATUS", "MySQL", "8.0.36").must_equal("SHOW MASTER STATUS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW MASTER STATUS", "MariaDB", "10.5.2-MariaDB").must_equal("SHOW BINLOG STATUS")
      Krikri::PluginHelpers::MysqlCommandResolver
        .resolve("SHOW MASTER STATUS", "MariaDB", "10.5.1-MariaDB").must_equal("SHOW MASTER STATUS")
    end
  end
end

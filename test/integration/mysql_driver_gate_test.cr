require "../minitest_helper"
require "../../src/krikri/plugin_helpers/mysql_connection"

# community.mysql/ansible.mysql's module-level driver gate (issue #885,
# stancel.create_mysql_dbs_and_users): a target whose Python can import
# neither PyMySQL nor MySQLdb fails every mysql_* task with upstream's
# mysql_driver_fail_msg BEFORE any connection attempt - the module body's
# own first gate, ahead of most of its parameter handling. krikri's
# plugins talk the wire protocol natively, so without this gate they
# carried on to their own connect failure (or success) where real ansible
# stops right here. The pinned ansible_python_interpreter vars stand in
# for interpreters with (/bin/true) and without (/bin/false) an
# importable driver - both run, so the probe's verdict is deterministic
# on any test host.
describe "mysql plugin driver gate" do
  NO_DRIVER  = {"ansible_python_interpreter" => "/bin/false"}
  HAS_DRIVER = {"ansible_python_interpreter" => "/bin/true"}

  it "fails mysql_db with the driver message before connecting or validating name" do
    # Upstream checks the driver before even the empty-name handling, so
    # no name: at all still fails with the driver message on a driverless
    # target, not the missing-argument one.
    result = PluginSpecHelper.run("mysql_db", {} of String => String, vars: NO_DRIVER)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(Krikri::PluginHelpers::MysqlConnection::MYSQL_DRIVER_FAIL_MSG)
  end

  it "fails mysql_user with the driver message before connecting" do
    result = PluginSpecHelper.run("mysql_user", {"name" => "alice"}, vars: NO_DRIVER)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(Krikri::PluginHelpers::MysqlConnection::MYSQL_DRIVER_FAIL_MSG)
  end

  it "fails mysql_info with the driver message before connecting" do
    result = PluginSpecHelper.run("mysql_info", {} of String => String, vars: NO_DRIVER)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(Krikri::PluginHelpers::MysqlConnection::MYSQL_DRIVER_FAIL_MSG)
  end

  it "fails mysql_query with the driver message before connecting" do
    result = PluginSpecHelper.run("mysql_query", {"query" => "SELECT 1"}, vars: NO_DRIVER)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(Krikri::PluginHelpers::MysqlConnection::MYSQL_DRIVER_FAIL_MSG)
  end

  it "fails mysql_variables with the driver message before connecting" do
    result = PluginSpecHelper.run("mysql_variables", {"variable" => "max_connections"}, vars: NO_DRIVER)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(Krikri::PluginHelpers::MysqlConnection::MYSQL_DRIVER_FAIL_MSG)
  end

  it "lets a target with an importable driver carry on past the gate" do
    # /bin/true stands in for a python that imports a driver: the gate
    # passes and the plugin reaches its own connect attempt (whose
    # failure shape is each plugin's own business, covered elsewhere).
    result = PluginSpecHelper.run("mysql_db", {"name" => "somedb", "login_password" => "x"}, vars: HAS_DRIVER)
    result["msg"]?.try(&.as_s?).wont_equal(Krikri::PluginHelpers::MysqlConnection::MYSQL_DRIVER_FAIL_MSG)
  end
end

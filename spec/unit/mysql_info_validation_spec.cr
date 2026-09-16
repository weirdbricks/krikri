require "../spec_helper"

# Pins plugins/mysql_info.cr's argument-validation surface against real
# community.mysql.mysql_info's AnsibleModule setup (mysql_common_
# argument_spec + mysql_info's own update; live-diffed vs real
# ansible-playbook via the podman-diff mysql_info_edge_cases harness).
# Only validation failures are unit-tested - anything past validation
# needs a live MariaDB (that path is covered by the podman-diff case
# file's functional tasks).
describe "mysql_info plugin argument validation" do
  it "rejects an unknown parameter with the full spec tail" do
    result = PluginSpecHelper.run("mysql_info", {
      "krikri_bogus"      => "x",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Unsupported parameters for (community.mysql.mysql_info) module: krikri_bogus. " \
      "Supported parameters include: ca_cert, check_hostname, client_cert, client_key, config_file, " \
      "connect_timeout, exclude_fields, filter, login_db, login_host, login_password, login_port, " \
      "login_unix_socket, login_user, return_empty_dbs (ssl_ca, ssl_cert, ssl_key).")
  end

  it "fails a non-integer login_port" do
    result = PluginSpecHelper.run("mysql_info", {
      "login_port"        => "notaport",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'login_port' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int")
  end

  it "fails a non-integer connect_timeout" do
    result = PluginSpecHelper.run("mysql_info", {
      "connect_timeout"   => "xyz",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'connect_timeout' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int")
  end

  it "fails a non-boolean return_empty_dbs" do
    result = PluginSpecHelper.run("mysql_info", {
      "return_empty_dbs"  => "notabool",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain(
      "argument 'return_empty_dbs' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean.  Valid booleans include: ")
  end

  it "accepts the ssl_ca alias for ca_cert during validation" do
    result = PluginSpecHelper.run("mysql_info", {
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
      "ssl_ca"            => "/tmp/no_such_ca.pem",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("Unsupported parameters")
  end
end

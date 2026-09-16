require "../spec_helper"

# Pins plugins/mysql_variables.cr's argument-validation and check-mode
# surface against real community.mysql.mysql_variables (live-diffed vs
# real ansible-playbook via the podman-diff mysql_variables_edge_cases
# harness): variable is required=True in the argument_spec (so a
# missing variable fails at setup, not with the module body's
# unreachable "Cannot run without variable" check), mode is a choices
# constraint, unsupported params are rejected with the full spec tail,
# and the module declares no supports_check_mode. The body-level
# invalid-name check runs before any connection, so it is testable
# without a server; anything else past validation needs a live MariaDB
# (covered by the podman-diff case file).
describe "mysql_variables plugin argument validation" do
  it "fails without variable at setup, not with the body check" do
    result = PluginSpecHelper.run("mysql_variables", {
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: variable")
  end

  it "fails the body-level invalid variable name check before connecting" do
    result = PluginSpecHelper.run("mysql_variables", {
      "variable"          => "krikri-bad!",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("invalid variable name \"krikri-bad!\"")
  end

  it "fails an invalid mode choice" do
    result = PluginSpecHelper.run("mysql_variables", {
      "variable"          => "version",
      "mode"              => "bogus",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of mode must be one of: global, persist, persist_only, got: bogus")
  end

  it "rejects an unknown parameter with the full spec tail" do
    result = PluginSpecHelper.run("mysql_variables", {
      "variable"          => "version",
      "krikri_bogus"      => "x",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Unsupported parameters for (community.mysql.mysql_variables) module: krikri_bogus. " \
      "Supported parameters include: ca_cert, check_hostname, client_cert, client_key, config_file, " \
      "connect_timeout, login_host, login_password, login_port, login_unix_socket, " \
      "login_user, mode, value, variable (ssl_ca, ssl_cert, ssl_key).")
  end

  it "fails a non-integer login_port" do
    result = PluginSpecHelper.run("mysql_variables", {
      "variable"          => "version",
      "login_port"        => "notaport",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'login_port' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int")
  end

  it "skips in check mode like a module without supports_check_mode" do
    result = PluginSpecHelper.run("mysql_variables", {
      "variable"            => "version",
      "login_user"          => "root",
      "login_unix_socket"   => "/run/mysqld/mysqld.sock",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_false
    result["skipped"].as_bool.should be_true
    result["msg"].as_s.should eq("remote module (community.mysql.mysql_variables) does not support check mode")
  end
end

require "../minitest_helper"

# Pins plugins/mysql_query.cr's argument-validation and check-mode
# surface against real community.mysql.mysql_query (live-diffed vs
# ansible-playbook via the podman-diff mysql_query_edge_cases harness):
# query required, positional_args|named_args mutually exclusive,
# single_transaction a bool, unsupported params rejected with the full
# spec tail, and no supports_check_mode (task skips with the "remote
# module (...) does not support check mode" shape). Functional
# DDL/DML/SELECT behavior needs a live MariaDB - covered by the
# podman-diff case file.
describe "mysql_query plugin argument validation" do
  it "fails without query" do
    result = PluginSpecHelper.run("mysql_query", {
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: query")
  end

  it "fails positional_args and named_args together" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"           => "SELECT 1",
      "positional_args" => "[1]",
      "named_args"      => "{\"krikri\": 1}",
      "login_user"      => "root",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: positional_args|named_args")
  end

  it "accepts positional_args and fails on too few for the placeholders before connecting" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"             => "DELETE FROM mysql.user WHERE User=%s AND Host=%s",
      "positional_args"   => "[\"\"]",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("not enough arguments for format string")
  end

  it "fails a non-boolean single_transaction" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"              => "SELECT 1",
      "single_transaction" => "notabool",
      "login_user"         => "root",
      "login_unix_socket"  => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(
      "argument 'single_transaction' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean. Valid booleans include: ")
  end

  it "rejects an unknown parameter with the full spec tail" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"             => "SELECT 1",
      "krikri_bogus"      => "x",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (community.mysql.mysql_query) module: krikri_bogus. " \
      "Supported parameters include: ca_cert, check_hostname, client_cert, client_key, config_file, " \
      "connect_timeout, login_db, login_host, login_password, login_port, login_unix_socket, " \
      "login_user, named_args, positional_args, query, session_vars, single_transaction " \
      "(ssl_ca, ssl_cert, ssl_key).")
  end

  it "fails a query that resolved to a non-string instead of sending it as SQL" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"             => Krikri::NON_STRING_PARAM_PREFIX + "4",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the query option value must be a string or list, passed <class 'int'>")
  end

  it "fails a non-string member of a query list before running any statement" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"             => [Krikri::NON_STRING_MEMBER_PREFIX + "4"].to_json,
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the elements in query list must be strings, passed '4' <class 'int'>")
  end

  it "checks the query type ahead of the driver gate" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"             => Krikri::NON_STRING_PARAM_PREFIX + "true",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    }, vars: {"ansible_python_interpreter" => "/bin/false"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the query option value must be a string or list, passed <class 'bool'>")
  end

  it "skips in check mode like a module without supports_check_mode" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"               => "SELECT 1",
      "login_user"          => "root",
      "login_unix_socket"   => "/run/mysqld/mysqld.sock",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("remote module (community.mysql.mysql_query) does not support check mode")
  end
end

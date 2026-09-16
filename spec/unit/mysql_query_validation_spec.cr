require "../spec_helper"

# Pins plugins/mysql_query.cr's argument-validation and check-mode
# surface against real community.mysql.mysql_query (live-diffed vs real
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: query")
  end

  it "fails positional_args and named_args together" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"           => "SELECT 1",
      "positional_args" => "[1]",
      "named_args"      => "{\"krikri\": 1}",
      "login_user"      => "root",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: positional_args|named_args")
  end

  it "fails a non-boolean single_transaction" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"               => "SELECT 1",
      "single_transaction"  => "notabool",
      "login_user"          => "root",
      "login_unix_socket"   => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain(
      "argument 'single_transaction' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean.  Valid booleans include: ")
  end

  it "rejects an unknown parameter with the full spec tail" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"             => "SELECT 1",
      "krikri_bogus"      => "x",
      "login_user"        => "root",
      "login_unix_socket" => "/run/mysqld/mysqld.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Unsupported parameters for (community.mysql.mysql_query) module: krikri_bogus. " \
      "Supported parameters include: ca_cert, check_hostname, client_cert, client_key, config_file, " \
      "connect_timeout, login_db, login_host, login_password, login_port, login_unix_socket, " \
      "login_user, named_args, positional_args, query, session_vars, single_transaction " \
      "(ssl_ca, ssl_cert, ssl_key).")
  end

  it "skips in check mode like a module without supports_check_mode" do
    result = PluginSpecHelper.run("mysql_query", {
      "query"               => "SELECT 1",
      "login_user"          => "root",
      "login_unix_socket"   => "/run/mysqld/mysqld.sock",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_false
    result["skipped"].as_bool.should be_true
    result["msg"].as_s.should eq("remote module (community.mysql.mysql_query) does not support check mode")
  end
end

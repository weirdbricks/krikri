require "../spec_helper"

# Pins plugins/postgresql_query.cr's argument-validation surface
# against real community.postgresql.postgresql_query (live-diffed vs
# real ansible-playbook via the podman-diff postgresql_query_edge_cases
# harness): in the live collection's argument_spec neither query nor
# login_db is required, the old `db:` spelling and the deprecated
# host/port/login/unix_socket aliases are NOT parameters at all,
# positional_args|named_args are mutually exclusive, login_port is an
# int, autocommit/trust_input are bools, ssl_mode is a choices
# constraint, and unsupported params are rejected LAST with the
# trailing all-aliases parenthetical. Validation failures happen
# before any connection, so these run without a PostgreSQL server.
describe "postgresql_query plugin argument validation" do
  it "fails on no parameters at all (nil query crashes the real module)" do
    result = PluginSpecHelper.run("postgresql_query", {} of String => String)

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq("MODULE FAILURE")
  end

  it "fails positional_args and named_args together" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"           => "SELECT 1",
      "positional_args" => "[1]",
      "named_args"      => "{\"krikri\": 1}",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: positional_args|named_args")
  end

  it "rejects the old db: spelling and unknown params, sorted, aliases trailing" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"        => "SELECT 1",
      "db"           => "krikri_db",
      "krikri_bogus" => "x",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Unsupported parameters for (community.postgresql.postgresql_query) module: db, krikri_bogus. " \
      "Supported parameters include: autocommit, ca_cert, connect_params, encoding, login_db, " \
      "login_host, login_password, login_port, login_unix_socket, login_user, named_args, " \
      "positional_args, query, search_path, session_role, ssl_cert, ssl_key, ssl_mode, " \
      "trust_input (ssl_rootcert).")
  end

  it "rejects the deprecated host alias like any other unsupported param" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query" => "SELECT 1",
      "host"  => "127.0.0.1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Unsupported parameters for (community.postgresql.postgresql_query) module: host. " \
      "Supported parameters include: autocommit, ca_cert, connect_params, encoding, login_db, " \
      "login_host, login_password, login_port, login_unix_socket, login_user, named_args, " \
      "positional_args, query, search_path, session_role, ssl_cert, ssl_key, ssl_mode, " \
      "trust_input (ssl_rootcert).")
  end

  it "fails an invalid ssl_mode choice" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"    => "SELECT 1",
      "ssl_mode" => "bogus",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "value of ssl_mode must be one of: allow, disable, prefer, require, verify-ca, verify-full, got: bogus")
  end

  it "fails a non-integer login_port" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"      => "SELECT 1",
      "login_port" => "notaport",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'login_port' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int")
  end

  it "fails a non-boolean autocommit" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"      => "SELECT 1",
      "autocommit" => "notabool",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain(
      "argument 'autocommit' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails a non-boolean trust_input" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"       => "SELECT 1",
      "trust_input" => "notabool",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain(
      "argument 'trust_input' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails autocommit together with check mode before connecting" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"               => "SELECT 1",
      "autocommit"          => "true",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Using autocommit is mutually exclusive with check_mode")
  end
end

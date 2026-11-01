require "../minitest_helper"
require "pg"
require "../../src/krikri/plugin_helpers/postgresql_connection"

# Pins plugins/postgresql_query.cr's argument-validation surface
# against real community.postgresql.postgresql_query 4.2.0
# (live-verified by running ansible-playbook 2.19.11 on this host,
# 2026-10-03): in the live collection's argument_spec neither query nor
# login_db is required, positional_args|named_args are mutually
# exclusive, login_port is an int, autocommit/trust_input are bools,
# ssl_mode is a choices constraint, the shared postgres_common_
# argument_spec's deprecated host/port/login/unix_socket/db aliases ARE
# accepted (so validation falls through to the connection attempt), and
# unsupported params are rejected LAST with the trailing all-aliases
# parenthetical and the module name as written in the task.
# Validation failures happen before any connection, so these run
# without a PostgreSQL server.
describe "postgresql_query plugin argument validation" do
  it "fails on no parameters at all (nil query crashes the Ansible module)" do
    result = PluginSpecHelper.run("postgresql_query", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("MODULE FAILURE")
  end

  it "fails positional_args and named_args together" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"           => "SELECT 1",
      "positional_args" => "[1]",
      "named_args"      => "{\"krikri\": 1}",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: positional_args|named_args")
  end

  it "rejects unknown params, sorted, aliases trailing, module name as written" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"        => "SELECT 1",
      "krikri_bogus" => "x",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (postgresql_query) module: krikri_bogus. " \
      "Supported parameters include: autocommit, ca_cert, connect_params, encoding, login_db, " \
      "login_host, login_password, login_port, login_unix_socket, login_user, named_args, " \
      "positional_args, query, search_path, session_role, ssl_cert, ssl_key, ssl_mode, " \
      "trust_input (db, host, login, port, ssl_rootcert, unix_socket).")
  end

  it "accepts the deprecated host/db aliases - it fails connecting, not validating" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query" => "SELECT 1",
      "db"    => "krikri_db",
      "host"  => "127.0.0.1",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.wont_include("Unsupported parameters")
  end

  it "fails an invalid ssl_mode choice" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"    => "SELECT 1",
      "ssl_mode" => "bogus",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of ssl_mode must be one of: allow, disable, prefer, require, verify-ca, verify-full, got: bogus")
  end

  it "fails a non-integer login_port" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"      => "SELECT 1",
      "login_port" => "notaport",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'login_port' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int")
  end

  it "fails a non-boolean autocommit" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"      => "SELECT 1",
      "autocommit" => "notabool",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(
      "argument 'autocommit' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean. Valid booleans include: ")
  end

  it "fails a non-boolean trust_input" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"       => "SELECT 1",
      "trust_input" => "notabool",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(
      "argument 'trust_input' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean. Valid booleans include: ")
  end

  it "fails autocommit together with check mode before connecting" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"               => "SELECT 1",
      "autocommit"          => "true",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Using autocommit is mutually exclusive with check_mode")
  end
end

# Issue #467 (consensys.web3signer): real community.postgresql's shared
# ensure_required_libs() fails the task with Ansible's missing_required_lib
# wording when the target's Python cannot import psycopg2 - after the
# argspec checks, before get_conn_params() and the connect. krikri's plugin
# talks the wire protocol through crystal-pg, needs no psycopg2, and used
# to carry on to its own "unable to connect to database: ... Connection
# refused" failure instead. The expectation depends on what the test host
# actually has, so the live-shape test probes the interpreter first; the
# helper test below is deterministic through a shimmed interpreter.
describe "postgresql_query psycopg2 library gate" do
  serial!

  def missing_library_message(library : String, python : String) : String
    "Failed to import the required Python library (#{library}) on #{System.hostname}'s Python #{python}. " \
    "Please read the module documentation and install it in the appropriate location. " \
    "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
    "please consult the documentation on ansible_python_interpreter"
  end

  it "fails with Ansible's missing_required_lib wording when python cannot import psycopg2" do
    python = Krikri.discovered_target_python
    skip "host has no python in Ansible's fallback list" unless python

    probe = Process.run(python, {"-c", "import psycopg2"}, error: Process::Redirect::Close)
    skip "host has psycopg2 installed" if probe.success?

    result = PluginSpecHelper.run("postgresql_query", {
      "query"      => "SELECT 1",
      "login_host" => "127.0.0.1",
      "login_port" => "59999",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(missing_library_message("psycopg2", Krikri.target_python_executable || python))
    result["warnings"]?.must_be_nil
  end

  it "keeps argument-validation errors ahead of the psycopg2 gate" do
    result = PluginSpecHelper.run("postgresql_query", {
      "query"           => "SELECT 1",
      "positional_args" => "[1]",
      "named_args"      => "{\"krikri\": 1}",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: positional_args|named_args")
  end

  it "builds the exact failed PluginResult for an interpreter missing psycopg2" do
    dir = PluginSpecHelper.tmp_path("psycopg2-gate-shim")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    interpreter = File.join(dir, Krikri::INTERPRETER_FALLBACK.first)
    File.write(interpreter, <<-SHIM)
      #!/bin/sh
      case "$*" in
        *"print(sys.executable)"*) echo "/opt/krikri-absent/bin/python3.13" ;;
        *"import psycopg2"*)
          echo "ModuleNotFoundError: No module named 'psycopg2'" >&2
          exit 1 ;;
        *) exit 0 ;;
      esac
      SHIM
    File.chmod(interpreter, 0o755)

    original_path = ENV["PATH"]?
    ENV["PATH"] = "#{dir}:#{original_path}"
    begin
      gate = Krikri::PluginHelpers::PostgresqlConnection.psycopg2_gate
      flunk "psycopg2_gate returned nil" unless gate
      gate.changed?.must_equal(false)
      gate.failed?.must_equal(true)
      gate.msg.must_equal(missing_library_message("psycopg2", "/opt/krikri-absent/bin/python3.13"))
    ensure
      ENV["PATH"] = original_path if original_path
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end
end

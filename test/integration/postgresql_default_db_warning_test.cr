require "../minitest_helper"
require "socket"

# The "no database passed" warning real (ansible-core 2.19.11 +
# community.postgresql 4.2.0) emits when a postgresql_* module is asked
# to connect without naming a database, against a throwaway PostgreSQL at
# 127.0.0.1:35434 (pended when nothing is listening there; the
# connection-refused cases need no server and always run).
#
# Real's module_utils/postgres.py calls
# `module.warn("Database name has not been passed, used default
# database to connect to.")` before connect_to_db(), and AnsibleModule's
# self.warn() does BOTH: prints `[WARNING]: <text>` on stderr and puts the
# text into the result's `warnings` list. Live-verified per module:
#
# - postgresql_query: warns on success AND on failure. Its result carries
#   `warnings` as the LAST key - after `failed` on a success result
#   (..., failed, warnings), after `exception` on a fail_json one, and
#   before `deprecations` when a deprecated alias is set too (live-verified
#   with `db:` + `host:` together: ..., failed, warnings, deprecations).
#   The `db:` alias counts as a database name, so a task passing it does
#   NOT warn (only the alias deprecation is reported).
# - postgresql_db / postgresql_user: NEVER warn - their own `db`/`name`
#   param is the database they manage, and real's result carries no
#   `warnings` key at all without a login_db.
# - postgresql_privs: real REQUIRES login_db (its pre-flight fails with
#   "missing required arguments: login_db"), so the warning can never
#   fire there; krikri keeps that result's key set free of `warnings`.
private def pg_warn_reachable? : Bool
  sock = TCPSocket.new("127.0.0.1", 35434, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

private WARN_LOGIN = {
  "login_host"     => "127.0.0.1",
  "login_port"     => "35434",
  "login_user"     => "postgres",
  "login_password" => "krikri",
}

private DEFAULT_DB_WARNING = "Database name has not been passed, used default database to connect to."

private REFUSED_MSG = "unable to connect to database: connection to server at \"127.0.0.1\", port 59999 failed: Connection refused\n" \
                      "\tIs the server running on that host and accepting TCP/IP connections?\n"

# The controller strips the `_ansible_*` engine markers before register
# (see TaskExecutor#register_result), so compare the registered shape.
private def reg_keys(result : JSON::Any) : Array(String)
  result.as_h.keys.reject { |key| key.starts_with?("_ansible_") }
end

describe "community.postgresql.* no-database warning (127.0.0.1:35434)" do
  # Shared external DB state (fixed database/role names): never run in
  # parallel with sibling workers (see test/minitest_helper.cr).
  serial!

  it "postgresql_query without login_db registers the default-database warning last" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    result = PluginSpecHelper.run("postgresql_query", WARN_LOGIN.merge({"query" => "SELECT 1"}))
    reg_keys(result).must_equal(["changed", "query", "query_list", "statusmessage", "query_result",
                                 "query_all_results", "rowcount", "execution_time_ms", "failed", "warnings"])
    result["warnings"].as_a.map(&.as_s).must_equal([DEFAULT_DB_WARNING])
  end

  it "postgresql_query with login_db registers no warnings key" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    result = PluginSpecHelper.run("postgresql_query", WARN_LOGIN.merge({"login_db" => "postgres", "query" => "SELECT 1"}))
    result["failed"].as_bool.must_equal(false)
    result["warnings"]?.must_be_nil
  end

  it "postgresql_query with the db alias registers no warnings key but does deprecate" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    result = PluginSpecHelper.run("postgresql_query", WARN_LOGIN.merge({"db" => "postgres", "query" => "SELECT 1"}))
    reg_keys(result).must_equal(["changed", "query", "query_list", "statusmessage", "query_result",
                                 "query_all_results", "rowcount", "execution_time_ms", "failed", "deprecations"])
    result["warnings"]?.must_be_nil
    result["deprecations"].as_a.size.must_equal(1)
  end

  it "postgresql_query orders warnings before deprecations when both apply" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    # `host:` alone (no `db:`) so the default-database warning fires AND
    # an alias deprecation is collected - real's order is
    # ..., failed, warnings, deprecations.
    result = PluginSpecHelper.run("postgresql_query",
      {"login_host" => "127.0.0.1", "host" => "127.0.0.1", "login_port" => "35434",
       "login_user" => "postgres", "login_password" => "krikri", "query" => "SELECT 1"})
    reg_keys(result).last(2).must_equal(["warnings", "deprecations"])
    result["warnings"].as_a.map(&.as_s).must_equal([DEFAULT_DB_WARNING])
  end

  it "postgresql_query connection failure without login_db still carries the warning" do
    # No server needed: the refused port fails before any query runs, and
    # real's warning rides along with the fail_json result.
    result = PluginSpecHelper.run("postgresql_query",
      {"login_host" => "127.0.0.1", "login_port" => "59999", "login_user" => "postgres", "query" => "SELECT 1"})
    reg_keys(result).must_equal(["failed", "msg", "changed", "exception", "warnings"])
    result["msg"].as_s.must_equal(REFUSED_MSG)
    result["warnings"].as_a.map(&.as_s).must_equal([DEFAULT_DB_WARNING])
  end

  it "postgresql_db without login_db registers no warnings key" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    PluginSpecHelper.run("postgresql_db", WARN_LOGIN.merge({"name" => "warn_db", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_db", WARN_LOGIN.merge({"name" => "warn_db", "state" => "present"}))
    result["failed"].as_bool.must_equal(false)
    result["warnings"]?.must_be_nil
    PluginSpecHelper.run("postgresql_db", WARN_LOGIN.merge({"name" => "warn_db", "state" => "absent"}))
  end

  it "postgresql_user without login_db registers no warnings key" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    PluginSpecHelper.run("postgresql_user", WARN_LOGIN.merge({"name" => "warn_u", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_user", WARN_LOGIN.merge({"name" => "warn_u"}))
    result["failed"].as_bool.must_equal(false)
    result["warnings"]?.must_be_nil
    PluginSpecHelper.run("postgresql_user", WARN_LOGIN.merge({"name" => "warn_u", "state" => "absent"}))
  end

  it "postgresql_privs without login_db registers no warnings key" do
    skip "no PostgreSQL server at 127.0.0.1:35434" unless pg_warn_reachable?
    result = PluginSpecHelper.run("postgresql_privs",
      WARN_LOGIN.merge({"role" => "warn_role", "privs" => "SELECT", "objs" => "TABLE", "state" => "absent"}))
    result["warnings"]?.must_be_nil
  end
end

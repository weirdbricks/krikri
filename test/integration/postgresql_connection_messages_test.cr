require "../minitest_helper"
require "socket"

# CONNECTION-FAILURE message parity for the community.postgresql.*
# plugins, against a throwaway PostgreSQL at 127.0.0.1:35433 (pended
# when nothing is listening there; the refused-port cases need no
# server at all and always run).
#
# Real (ansible-core 2.19.11 + community.postgresql 4.2.0) does not
# word a failed connect itself: module_utils/postgres.py's
# connect_to_db() fails with
#   module.fail_json(msg="unable to connect to database: %s" % conn_err)
# where conn_err is libpq's own connection-error text, so that is
# exactly what each string below is - live-verified against real for
# every case:
#
# - refused TCP port:
#   unable to connect to database: connection to server at "127.0.0.1",
#   port 59999 failed: Connection refused\n\tIs the server running on
#   that host and accepting TCP/IP connections?\n
# - missing Unix socket directory:
#   unable to connect to database: connection to server on socket
#   "/nonexistent/sockdir/.s.PGSQL.5432" failed: No such file or
#   directory\n\tIs the server running locally and accepting
#   connections on that socket?\n
# - wrong password (the server answered, so the text is its own
#   ErrorResponse and NO hint line follows):
#   unable to connect to database: connection to server at "127.0.0.1",
#   port 35433 failed: FATAL:  password authentication failed for user
#   "postgres"\n
# - nonexistent database:
#   unable to connect to database: connection to server at "127.0.0.1",
#   port 35433 failed: FATAL:  database "nosuchdb" does not exist\n
#
# Registered shape is real's plain fail_json(msg=...) one:
# {failed, msg, changed, exception} - krikri emits no deprecations key
# for these (no alias param is set in any of these cases).
#
# Deliberate limit: an unresolvable host prints libpq's DNS wording
# ("could not translate host name ... to address: Name or service not
# known\n") from the EAI_NONAME case only - Crystal's
# Socket::Addrinfo::Error carries no gai code, so a TEMPORARY resolver
# failure ("Temporary failure in name resolution" in real) is
# indistinguishable here. Likewise the strerror strings above are
# libc's, so a non-glibc host prints this host's own translations.
private def pg2_reachable? : Bool
  sock = TCPSocket.new("127.0.0.1", 35433, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

private CONN_LOGIN = {
  "login_host"     => "127.0.0.1",
  "login_user"     => "postgres",
  "login_password" => "krikri",
}

private REFUSED_MSG = "unable to connect to database: connection to server at \"127.0.0.1\", port 59999 failed: Connection refused\n" \
                      "\tIs the server running on that host and accepting TCP/IP connections?\n"

private def assert_conn_failure(result : JSON::Any, msg : String)
  result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
  result["failed"].as_bool.must_equal(true)
  result["msg"].as_s.must_equal(msg)
  result["changed"].as_bool.must_equal(false)
end

describe "community.postgresql.* connection-failure messages (127.0.0.1:35433)" do
  # Shared external DB state (a fixed login/database name) and the
  # closed-port probe: never run in parallel with sibling workers
  # (see test/minitest_helper.cr).
  serial!

  it "postgresql_query refused port reports libpq's connection-refused text" do
    result = PluginSpecHelper.run("postgresql_query",
      CONN_LOGIN.merge({"login_port" => "59999", "query" => "SELECT 1"}))
    assert_conn_failure(result, REFUSED_MSG)
  end

  it "postgresql_db refused port reports libpq's connection-refused text" do
    result = PluginSpecHelper.run("postgresql_db",
      CONN_LOGIN.merge({"login_port" => "59999", "name" => "connfail_db", "state" => "present"}))
    assert_conn_failure(result, REFUSED_MSG)
  end

  it "postgresql_user refused port reports libpq's connection-refused text" do
    result = PluginSpecHelper.run("postgresql_user",
      CONN_LOGIN.merge({"login_port" => "59999", "name" => "connfail_user"}))
    assert_conn_failure(result, REFUSED_MSG)
  end

  it "postgresql_privs refused port reports libpq's connection-refused text" do
    result = PluginSpecHelper.run("postgresql_privs",
      CONN_LOGIN.merge({"login_port" => "59999", "db" => "postgres", "privs" => "SELECT", "objs" => "TABLE", "role" => "connfail_role"}))
    assert_conn_failure(result, REFUSED_MSG)
  end

  it "postgresql_query missing unix socket directory reports libpq's socket text" do
    result = PluginSpecHelper.run("postgresql_query",
      {"login_unix_socket" => "/nonexistent/sockdir", "login_user" => "postgres", "query" => "SELECT 1"})
    assert_conn_failure(result,
      "unable to connect to database: connection to server on socket \"/nonexistent/sockdir/.s.PGSQL.5432\" failed: No such file or directory\n" \
      "\tIs the server running locally and accepting connections on that socket?\n")
  end

  it "postgresql_query wrong password reports the server's own FATAL text" do
    skip "no PostgreSQL server at 127.0.0.1:35433" unless pg2_reachable?
    result = PluginSpecHelper.run("postgresql_query",
      CONN_LOGIN.merge({"login_port" => "35433", "login_password" => "wrongpw", "query" => "SELECT 1"}))
    assert_conn_failure(result,
      "unable to connect to database: connection to server at \"127.0.0.1\", port 35433 failed: FATAL:  password authentication failed for user \"postgres\"\n")
  end

  it "postgresql_query nonexistent database reports the server's own FATAL text" do
    skip "no PostgreSQL server at 127.0.0.1:35433" unless pg2_reachable?
    result = PluginSpecHelper.run("postgresql_query",
      CONN_LOGIN.merge({"login_port" => "35433", "login_db" => "nosuchdb", "query" => "SELECT 1"}))
    assert_conn_failure(result,
      "unable to connect to database: connection to server at \"127.0.0.1\", port 35433 failed: FATAL:  database \"nosuchdb\" does not exist\n")
  end

  it "postgresql_db wrong password reports the server's own FATAL text" do
    skip "no PostgreSQL server at 127.0.0.1:35433" unless pg2_reachable?
    result = PluginSpecHelper.run("postgresql_db",
      CONN_LOGIN.merge({"login_port" => "35433", "login_password" => "wrongpw", "name" => "connfail_db2", "state" => "present"}))
    assert_conn_failure(result,
      "unable to connect to database: connection to server at \"127.0.0.1\", port 35433 failed: FATAL:  password authentication failed for user \"postgres\"\n")
  end
end

require "../minitest_helper"
require "db"
require "pg"
require "socket"
require "../../src/krikri/plugin_helpers/postgresql_connection"

# CONNECT_TIMEOUT parity for the community.postgresql.* plugins.
#
# Real (psycopg2/libpq) honors two ways to bound a connection attempt:
# connect_params, and libpq's
# PGCONNECT_TIMEOUT environment variable (PGCONNECT_TIMEOUT is only
# consulted when the conninfo keyword is absent). On expiry libpq words
# the failure exactly
#
#   connection to server at "H", port N failed: timeout expired\n
#
# with NO "Is the server running..." hint line - unlike the errno path
# (Connection refused / Network is unreachable / Connection timed out),
# which always carries one. That wording is taken from libpq's own
# source (fe-connect.c's connect-timeout handling: "timeout expired")
# and is UNVERIFIED against real ansible until checked on a real host.
# A natural (unbounded) connect instead words the OS-level ETIMEDOUT
# path "Connection timed out" WITH the hint line (live-verified against
# real with PGCONNECT_TIMEOUT unset, see io_error_detail's own comment
# in src/krikri/plugin_helpers/postgresql_connection.cr).
#
# crystal-pg itself has no connect timeout, so krikri bounds the
# connect attempt of `DB.open` in PostgresqlConnection.open - only the
# attempt, never the module block - and marks the resulting
# ConnectionRefused with the deadline, which pg_connection_failed then
# words with libpq's "timeout expired" text.
#
# Test targets here are NOT the network: a local TCP listener that
# accepts and holds the connection without ever completing the
# PostgreSQL startup handshake (crystal-pg's connect() then blocks
# forever waiting for the server's auth/response frames), so the
# DB-level deadline - not the OS connect timeout, not a refusal - is
# what fires. A listener that never accepts is not enough: connect()
# to a backlog-full listener still returns quickly, and a refused port
# never reaches the timeout path at all.
private def with_held_listener(& : Int32 ->)
  listener = TCPServer.new("127.0.0.1", 0)
  begin
    held = Channel(Socket?).new
    accept_fiber = spawn do
      # Accept but never speak: no startup-packet reply, so the
      # client's startup/auth exchange never completes.
      sock = listener.accept?
      held.send(sock)
    end
    yield listener.local_address.port
  ensure
    listener.close
  end
end

private CONN_LOGIN = {
  "login_host"     => "127.0.0.1",
  "login_user"     => "postgres",
  "login_password" => "krikri",
}

private def assert_timeout_msg(result : JSON::Any, port : Int32, with_db_alias : Bool = false, with_db_warning : Bool = false)
  expected = ["failed", "msg", "changed", "exception"]
  expected << "warnings" if with_db_warning
  expected << "deprecations" if with_db_alias
  result.as_h.keys.reject { |key| key.starts_with?("_ansible_") }.must_equal(expected)
  result["failed"].as_bool.must_equal(true)
  result["msg"].as_s.must_equal(
    "unable to connect to database: connection to server at \"127.0.0.1\", port #{port} failed: timeout expired\n")
  result["changed"].as_bool.must_equal(false)
end

describe "community.postgresql.* connect_timeout (held listener)" do
  serial!

  it "postgresql_query honors connect_timeout param with libpq's timeout-expired text" do
    with_held_listener do |port|
      result = PluginSpecHelper.run("postgresql_query",
        CONN_LOGIN.merge({"login_port" => port.to_s, "connect_params" => %({"connect_timeout": 1}), "query" => "SELECT 1"}))
      assert_timeout_msg(result, port, with_db_warning: true)
    end
  end

  it "postgresql_query honors PGCONNECT_TIMEOUT env with the same text" do
    with_held_listener do |port|
      result = PluginSpecHelper.run("postgresql_query",
        CONN_LOGIN.merge({"login_port" => port.to_s, "query" => "SELECT 1"}),
        env: {"PGCONNECT_TIMEOUT" => "1"})
      assert_timeout_msg(result, port, with_db_warning: true)
    end
  end

  it "connect_timeout param wins over PGCONNECT_TIMEOUT env" do
    with_held_listener do |port|
      # Param of 1 vs env of 30: the DB-level deadline must fire at ~1s,
      # NOT be clobbered by the env value.
      result = PluginSpecHelper.run("postgresql_query",
        CONN_LOGIN.merge({"login_port" => port.to_s, "connect_params" => %({"connect_timeout": 1}), "query" => "SELECT 1"}),
        env: {"PGCONNECT_TIMEOUT" => "30"})
      assert_timeout_msg(result, port, with_db_warning: true)
    end
  end

  it "postgresql_db honors connect_timeout param with libpq's timeout-expired text" do
    with_held_listener do |port|
      result = PluginSpecHelper.run("postgresql_db",
        CONN_LOGIN.merge({"login_port" => port.to_s, "connect_params" => %({"connect_timeout": 1}), "name" => "pgtimeout_db", "state" => "present"}))
      assert_timeout_msg(result, port)
    end
  end

  it "postgresql_user honors connect_timeout param with libpq's timeout-expired text" do
    with_held_listener do |port|
      result = PluginSpecHelper.run("postgresql_user",
        CONN_LOGIN.merge({"login_port" => port.to_s, "connect_params" => %({"connect_timeout": 1}), "name" => "pgtimeout_user"}))
      assert_timeout_msg(result, port)
    end
  end

  it "postgresql_privs honors connect_timeout param with libpq's timeout-expired text" do
    with_held_listener do |port|
      result = PluginSpecHelper.run("postgresql_privs",
        CONN_LOGIN.merge({"login_port" => port.to_s, "connect_params" => %({"connect_timeout": 1}), "db" => "postgres",
                          "privs" => "SELECT", "objs" => "TABLE", "role" => "pgtimeout_role"}))
      assert_timeout_msg(result, port, with_db_alias: true)
    end
  end
end

# Unit level: PostgresqlConnection.connect_timeout precedence/parse
# rules (param first, then PGCONNECT_TIMEOUT, then unbounded; a
# non-positive or non-integer value never produces a deadline).
describe "PostgresqlConnection.connect_timeout resolution" do
  serial!

  it "prefers the connect_timeout param over PGCONNECT_TIMEOUT" do
    PluginSpecHelper::STATE_MUTEX.synchronize do
      old = ENV["PGCONNECT_TIMEOUT"]?
      begin
        ENV["PGCONNECT_TIMEOUT"] = "30"
        Krikri::PluginHelpers::PostgresqlConnection.connect_timeout({"connect_params" => %({"connect_timeout": 2})}).must_equal(2.seconds)
      ensure
        if old
          ENV["PGCONNECT_TIMEOUT"] = old
        else
          ENV.delete("PGCONNECT_TIMEOUT")
        end
      end
    end
  end

  it "reads PGCONNECT_TIMEOUT from the task environment param, ahead of the process ENV" do
    PluginSpecHelper::STATE_MUTEX.synchronize do
      old = ENV["PGCONNECT_TIMEOUT"]?
      begin
        ENV["PGCONNECT_TIMEOUT"] = "30"
        Krikri::PluginHelpers::PostgresqlConnection.connect_timeout({"_environment" => %({"PGCONNECT_TIMEOUT": "3"})}).must_equal(3.seconds)
      ensure
        if old
          ENV["PGCONNECT_TIMEOUT"] = old
        else
          ENV.delete("PGCONNECT_TIMEOUT")
        end
      end
    end
  end

  it "falls back to PGCONNECT_TIMEOUT when no param is set" do
    PluginSpecHelper::STATE_MUTEX.synchronize do
      old = ENV["PGCONNECT_TIMEOUT"]?
      begin
        ENV["PGCONNECT_TIMEOUT"] = "7"
        Krikri::PluginHelpers::PostgresqlConnection.connect_timeout({} of String => String).must_equal(7.seconds)
      ensure
        if old
          ENV["PGCONNECT_TIMEOUT"] = old
        else
          ENV.delete("PGCONNECT_TIMEOUT")
        end
      end
    end
  end

  it "is unbounded when neither is set or neither parses positive" do
    PluginSpecHelper::STATE_MUTEX.synchronize do
      old = ENV["PGCONNECT_TIMEOUT"]?
      begin
        ENV.delete("PGCONNECT_TIMEOUT")
        Krikri::PluginHelpers::PostgresqlConnection.connect_timeout({} of String => String).must_be_nil
        Krikri::PluginHelpers::PostgresqlConnection.connect_timeout({"connect_params" => %({"connect_timeout": 0})}).must_be_nil
        Krikri::PluginHelpers::PostgresqlConnection.connect_timeout({"connect_params" => %({"connect_timeout": "xyz"})}).must_be_nil
      ensure
        if old
          ENV["PGCONNECT_TIMEOUT"] = old
        else
          ENV.delete("PGCONNECT_TIMEOUT")
        end
      end
    end
  end
end

# Regression for the block-under-deadline bug: only the connect attempt
# is bounded. Once DB.open returns, the module block runs in the
# caller's fiber with no deadline, so a query slower than
# connect_timeout must complete normally instead of being misreported
# as "timeout expired". The server is a fake answering just enough of
# the PostgreSQL protocol (AuthenticationOk + ReadyForQuery, after
# swallowing the startup packet; sslmode=disable skips SSL negotiation)
# for crystal-pg to consider the connection established - no real PG
# server is needed and no query is ever issued (the block only sleeps
# past the deadline).
private PG_AUTH_OK = UInt8.slice(0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00)

private PG_READY_FOR_QUERY = UInt8.slice(0x5A, 0x00, 0x00, 0x00, 0x05, 0x49)

private def with_fake_pg_handshake(& : Int32 ->)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.port
  sock = nil.as(TCPSocket?)
  # The accept + handshake runs in its own fiber: the client only
  # connects once the block below starts, so accepting inline would
  # deadlock.
  spawn do
    if client = listener.accept?
      sock = client
      begin
        # Startup packet: int32 total length, then length-4 bytes of
        # body (protocol 3.0 + params) - read and discarded.
        len = client.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
        client.skip(len - 4)
        client.write(PG_AUTH_OK)
        client.write(PG_READY_FOR_QUERY)
        client.flush
      rescue IO::Error
      end
    end
  end
  begin
    yield port
  ensure
    sock.try(&.close)
    listener.close
  end
end

describe "PostgresqlConnection.open bounds only the connect attempt" do
  it "a slow block after connect is not reported as a connect timeout" do
    with_fake_pg_handshake do |port|
      uri = "postgres://postgres:krikri@127.0.0.1:#{port}/postgres?sslmode=disable"
      started = Time.instant
      result = Krikri::PluginHelpers::PostgresqlConnection.open(uri, {"connect_params" => %({"connect_timeout": 1})}) do |conn|
        conn.class.name.must_equal("DB::Database")
        sleep 2.seconds
        "slow block finished"
      end
      result.must_equal("slow block finished")
      elapsed = (Time.instant - started).total_seconds
      (elapsed >= 2).must_equal(true)
    end
  end
end

require "../minitest_helper"
require "socket"

# Registered-result SHAPE spec for the community.postgresql.* plugins,
# against a throwaway PostgreSQL at 127.0.0.1:35432 (pended when nothing
# is listening there).
#
# Every shape asserted here was live-verified against real ansible-core
# 2.19.11 + community.postgresql 4.2.0 on a real PostgreSQL 17 server:
#
# - postgresql_db's exit_json(changed=..., db=db, executed_commands=[...])
#   registers exactly {changed, db, executed_commands, failed} - no msg,
#   with failed:false backfilled by the controller after the module's own
#   kwargs, hence its position. executed_commands is the list of SQL
#   strings actually sent (mogrify'd), empty in check mode.
# - postgresql_user's exit_json(**kw) with kw = dict(user=...) then
#   changed, then queries (plus user_removed when state: absent and a
#   role was there): {user, changed, queries, failed}.
# - postgresql_privs' exit_json(changed=..., queries=...):
#   {changed, queries, failed}.
# - postgresql_query's kw dict: {changed, query, query_list, statusmessage,
#   query_result, query_all_results, rowcount, execution_time_ms, failed}.
#
# A FAILED postgresql_* result (e.g. the engine's own
# "missing required arguments: db" pre-flight) is real's plain fail_json
# shape - {failed, msg, changed, exception} - which is what the shared
# argument-spec path now emits.
private def shape_postgres_reachable? : Bool
  sock = TCPSocket.new("127.0.0.1", 35432, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

private SHAPE_LOGIN = {
  "login_host"     => "127.0.0.1",
  "login_port"     => "35432",
  "login_user"     => "postgres",
  "login_password" => "krikri",
}

private def shape_keys(result : JSON::Any) : Array(String)
  result.as_h.keys
end

describe "community.postgresql.* registered result shape (127.0.0.1:35432)" do
  it "postgresql_db create registers changed/db/executed_commands/failed and no msg" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db1", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db1", "state" => "present"}))
    shape_keys(result).must_equal(["changed", "db", "executed_commands", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["db"].as_s.must_equal("shape_db1")
    result["executed_commands"].as_a.map(&.as_s).must_equal(["CREATE DATABASE \"shape_db1\""])
    result["failed"].as_bool.must_equal(false)
    result["msg"]?.try(&.as_s).must_be_nil
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db1", "state" => "absent"}))
  end

  it "postgresql_db rerun is unchanged with an empty executed_commands" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db2", "state" => "absent"}))
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db2", "state" => "present"}))
    result = PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db2", "state" => "present"}))
    shape_keys(result).must_equal(["changed", "db", "executed_commands", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["executed_commands"].as_a.must_be_empty
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db2", "state" => "absent"}))
  end

  it "postgresql_db check mode reports changed with no executed SQL" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db3", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({
      "name" => "shape_db3", "state" => "present", "_ansible_check_mode" => "true",
    }))
    shape_keys(result).must_equal(["changed", "db", "executed_commands", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["executed_commands"].as_a.must_be_empty
  end

  it "postgresql_db drop registers the DROP statement in executed_commands" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db4", "state" => "absent"}))
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db4", "state" => "present"}))
    result = PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db4", "state" => "absent"}))
    shape_keys(result).must_equal(["changed", "db", "executed_commands", "failed"])
    result["executed_commands"].as_a.map(&.as_s).must_equal(["DROP DATABASE \"shape_db4\""])
    result["failed"].as_bool.must_equal(false)
  end

  it "postgresql_db owner/encoding land in the recorded CREATE statement" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db5", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({
      "name" => "shape_db5", "state" => "present", "owner" => "postgres", "encoding" => "UTF-8",
    }))
    result["executed_commands"].as_a.map(&.as_s).must_equal([
      "CREATE DATABASE \"shape_db5\" OWNER \"postgres\" ENCODING 'UTF-8'",
    ])
    PluginSpecHelper.run("postgresql_db", SHAPE_LOGIN.merge({"name" => "shape_db5", "state" => "absent"}))
  end
end

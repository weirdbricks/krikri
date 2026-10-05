require "../minitest_helper"
require "socket"

# Registered-result SHAPE spec for the community.postgresql.* plugins,
# against a throwaway PostgreSQL at 127.0.0.1:35432 (pended when nothing
# is listening there).
#
# Every shape asserted here was live-verified against ansible-core
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
# "missing required arguments: db" pre-flight) is Ansible's plain fail_json
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
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

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

describe "postgresql_user registered result shape (127.0.0.1:35432)" do
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

  it "create registers user/changed/queries/failed with the CREATE template" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u1", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u1"}))
    shape_keys(result).must_equal(["user", "changed", "queries", "failed"])
    result["user"].as_s.must_equal("shape_u1")
    result["changed"].as_bool.must_equal(true)
    # Ansible's user_add() leaves the %(password)s placeholder literal and
    # appends the (empty) flags string, hence the trailing space.
    result["queries"].as_a.map(&.as_s).must_equal(["CREATE USER \"shape_u1\" "])
    result["failed"].as_bool.must_equal(false)
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u1", "state" => "absent"}))
  end

  it "create with a password and role_attr_flags records both fragments" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u2", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({
      "name" => "shape_u2", "password" => "sekrit1", "role_attr_flags" => "NOSUPERUSER,NOCREATEDB",
    }))
    shape_keys(result).must_equal(["user", "changed", "queries", "failed"])
    result["queries"].as_a.map(&.as_s).must_equal([
      "CREATE USER \"shape_u2\" WITH ENCRYPTED PASSWORD %(password)s NOSUPERUSER NOCREATEDB",
    ])
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u2", "state" => "absent"}))
  end

  it "an unchanged repeat call reports no queries at all" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u3", "state" => "absent"}))
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u3", "password" => "sekrit2"}))
    result = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u3", "password" => "sekrit2"}))
    shape_keys(result).must_equal(["user", "changed", "queries", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["queries"].as_a.must_be_empty
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u3", "state" => "absent"}))
  end

  it "a password change records the ALTER template, and a flag change the WITH form" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u4", "state" => "absent"}))
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u4"}))
    pw_change = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u4", "password" => "sekrit3"}))
    pw_change["queries"].as_a.map(&.as_s).must_equal([
      "ALTER USER \"shape_u4\" WITH ENCRYPTED PASSWORD %(password)s ",
    ])
    flag_change = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({
      "name" => "shape_u4", "role_attr_flags" => "CREATEDB",
    }))
    flag_change["queries"].as_a.map(&.as_s).must_equal(["ALTER USER \"shape_u4\" WITH CREATEDB"])
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u4", "state" => "absent"}))
  end

  it "absent on an existing role adds user_removed and the DROP statement" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u5", "state" => "absent"}))
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u5"}))
    result = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u5", "state" => "absent"}))
    shape_keys(result).must_equal(["user", "user_removed", "changed", "queries", "failed"])
    result["user_removed"].as_bool.must_equal(true)
    result["queries"].as_a.map(&.as_s).must_equal(["DROP USER \"shape_u5\""])
    gone = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u5", "state" => "absent"}))
    shape_keys(gone).must_equal(["user", "changed", "queries", "failed"])
    gone["changed"].as_bool.must_equal(false)
  end

  it "check mode absent reports user_removed with no executed statement" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u6", "state" => "absent"}))
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u6"}))
    result = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({
      "name" => "shape_u6", "state" => "absent", "_ansible_check_mode" => "true",
    }))
    shape_keys(result).must_equal(["user", "user_removed", "changed", "queries", "failed"])
    result["user_removed"].as_bool.must_equal(true)
    result["queries"].as_a.must_be_empty
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u6", "state" => "absent"}))
  end

  it "check mode create still records the CREATE template" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u7", "state" => "absent"}))
    result = PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({
      "name" => "shape_u7", "_ansible_check_mode" => "true",
    }))
    shape_keys(result).must_equal(["user", "changed", "queries", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["queries"].as_a.map(&.as_s).must_equal(["CREATE USER \"shape_u7\" "])
    PluginSpecHelper.run("postgresql_user", SHAPE_LOGIN.merge({"name" => "shape_u7", "state" => "absent"}))
  end

  # ---- postgresql_privs -------------------------------------------------
  #
  # Ansible builds ONE statement from the module params (its own
  # QueryBuilder), appends it to executed_queries and reports the whole
  # list under `queries` - unconditionally, whether or not it ended up
  # changing anything (its `changed` comes from diffing the ACL before and
  # after it ran). Live-verified against ansible-core 2.19.11 +
  # community.postgresql 4.2.0.

  private PRIVS_SETUP_SQL = [
    {"shape_pg_privs_role", "CREATE ROLE"},
    {"shape_pg_privs_mem", "CREATE ROLE"},
    {"shape_pg_privs_grp", "CREATE ROLE"},
    {"shape_pg_privs_owner", "CREATE ROLE"},
  ]

  private def privs_reset : Nil
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP TABLE IF EXISTS shape_pg_t1"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP SCHEMA IF EXISTS shape_pg_sc CASCADE"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP SEQUENCE IF EXISTS shape_pg_s1"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP TYPE IF EXISTS shape_pg_ty"}))
    PRIVS_SETUP_SQL.each do |name, verb|
      PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP OWNED BY #{name} CASCADE"}))
      PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP ROLE IF EXISTS #{name}"}))
      PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "#{verb} #{name}"}))
    end
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "CREATE TABLE shape_pg_t1 (id int)"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "CREATE SCHEMA shape_pg_sc"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "CREATE SEQUENCE shape_pg_s1"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "CREATE TYPE shape_pg_ty AS (a int)"}))
  end

  private def privs_result_for(params : Hash(String, String)) : JSON::Any
    PluginSpecHelper.run("postgresql_privs", SHAPE_LOGIN.merge(params))
  end

  it "postgresql_privs grant registers changed/queries/failed and no msg" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON table \"public\".\"shape_pg_t1\" TO \"shape_pg_privs_role\";"])
    result["failed"].as_bool.must_equal(false)
    result["msg"]?.try(&.as_s).must_be_nil
  end

  it "postgresql_privs revoke registers the REVOKE statement" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                      "roles" => "shape_pg_privs_role", "privs" => "SELECT"})
    result = privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT", "state" => "absent"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["queries"].as_a.map(&.as_s).must_equal(
      ["REVOKE SELECT ON table \"public\".\"shape_pg_t1\" FROM \"shape_pg_privs_role\";"])
  end

  it "postgresql_privs unchanged still reports the full GRANT it built" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    params = {"type" => "table", "objs" => "shape_pg_t1",
              "roles" => "shape_pg_privs_role", "privs" => "SELECT"}
    privs_result_for(params)
    result = privs_result_for(params)
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON table \"public\".\"shape_pg_t1\" TO \"shape_pg_privs_role\";"])
  end

  it "postgresql_privs check mode reports the same GRANT with no execution" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT",
                               "_ansible_check_mode" => "true"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON table \"public\".\"shape_pg_t1\" TO \"shape_pg_privs_role\";"])
  end

  it "postgresql_privs sequence/schema/type/database spell their own object kind" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    seq = privs_result_for({"type" => "sequence", "objs" => "shape_pg_s1",
                            "roles" => "shape_pg_privs_role", "privs" => "SELECT"})
    seq["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON sequence \"public\".\"shape_pg_s1\" TO \"shape_pg_privs_role\";"])

    sch = privs_result_for({"type" => "schema", "objs" => "shape_pg_sc",
                            "roles" => "shape_pg_privs_role", "privs" => "CREATE"})
    sch["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT CREATE ON schema \"shape_pg_sc\" TO \"shape_pg_privs_role\";"])

    ty = privs_result_for({"type" => "type", "objs" => "shape_pg_ty",
                           "roles" => "shape_pg_privs_role", "privs" => "USAGE"})
    ty["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT USAGE ON type \"public\".\"shape_pg_ty\" TO \"shape_pg_privs_role\";"])

    db = privs_result_for({"type" => "database", "objs" => "postgres",
                           "roles" => "shape_pg_privs_role", "privs" => "CREATE"})
    db["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT CREATE ON database \"postgres\" TO \"shape_pg_privs_role\";"])
  end

  it "postgresql_privs all_in_schema uses Ansible's ALL TABLES IN SCHEMA clause" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "table", "objs" => "ALL_IN_SCHEMA",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON ALL TABLES IN SCHEMA \"public\" TO \"shape_pg_privs_role\";"])
  end

  it "postgresql_privs group emits GRANT role TO member" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "group", "objs" => "shape_pg_privs_grp",
                               "roles" => "shape_pg_privs_mem"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT \"shape_pg_privs_grp\" TO \"shape_pg_privs_mem\";"])

    with_admin = privs_result_for({"type" => "group", "objs" => "shape_pg_privs_grp",
                                   "roles" => "shape_pg_privs_mem", "grant_option" => "true"})
    with_admin["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT \"shape_pg_privs_grp\" TO \"shape_pg_privs_mem\" WITH ADMIN OPTION;"])

    revoked = privs_result_for({"type" => "group", "objs" => "shape_pg_privs_grp",
                                "roles" => "shape_pg_privs_mem", "state" => "absent"})
    revoked["queries"].as_a.map(&.as_s).must_equal(
      ["REVOKE \"shape_pg_privs_grp\" FROM \"shape_pg_privs_mem\";"])
  end

  it "postgresql_privs grant_option false adds Ansible's REVOKE GRANT OPTION FOR line" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT",
                               "grant_option" => "true"})
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON table \"public\".\"shape_pg_t1\" TO \"shape_pg_privs_role\" WITH GRANT OPTION;"])

    stripped = privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                                 "roles" => "shape_pg_privs_role", "privs" => "SELECT",
                                 "grant_option" => "false"})
    stripped["queries"].as_a.map(&.as_s).must_equal([
      "GRANT SELECT ON table \"public\".\"shape_pg_t1\" TO \"shape_pg_privs_role\";\n" \
      "REVOKE GRANT OPTION FOR SELECT ON table \"public\".\"shape_pg_t1\" FROM \"shape_pg_privs_role\";",
    ])
  end

  it "postgresql_privs default_privs pairs REVOKE ALL with GRANT in one entry" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "default_privs", "objs" => "TABLES",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["queries"].as_a.map(&.as_s).must_equal([
      "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON TABLES FROM \"shape_pg_privs_role\";\n" \
      "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" GRANT SELECT ON TABLES TO \"shape_pg_privs_role\";",
    ])

    absent = privs_result_for({"type" => "default_privs", "objs" => "TABLES",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT", "state" => "absent"})
    absent["queries"].as_a.map(&.as_s).must_equal([
      "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON TABLES FROM \"shape_pg_privs_role\";\n" \
      "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON FUNCTIONS FROM \"shape_pg_privs_role\";\n" \
      "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON SEQUENCES FROM \"shape_pg_privs_role\";\n" \
      "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON TYPES FROM \"shape_pg_privs_role\";",
    ])
  end

  it "postgresql_privs default_privs target_roles adds Ansible's FOR ROLE clause" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "default_privs", "objs" => "TABLES",
                               "roles" => "shape_pg_privs_role", "privs" => "SELECT",
                               "target_roles" => "shape_pg_privs_owner"})
    result["queries"].as_a.map(&.as_s).must_equal([
      "ALTER DEFAULT PRIVILEGES FOR ROLE \"shape_pg_privs_owner\" IN SCHEMA \"public\" " \
      "REVOKE ALL ON TABLES FROM \"shape_pg_privs_role\";\n" \
      "ALTER DEFAULT PRIVILEGES FOR ROLE \"shape_pg_privs_owner\" IN SCHEMA \"public\" " \
      "GRANT SELECT ON TABLES TO \"shape_pg_privs_role\";",
    ])
  end

  it "postgresql_privs PUBLIC grantee stays an unquoted uppercase keyword" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    privs_reset
    result = privs_result_for({"type" => "table", "objs" => "shape_pg_t1",
                               "roles" => "PUBLIC", "privs" => "SELECT"})
    shape_keys(result).must_equal(["changed", "queries", "failed"])
    result["queries"].as_a.map(&.as_s).must_equal(
      ["GRANT SELECT ON table \"public\".\"shape_pg_t1\" TO PUBLIC;"])
  end

  # ---- postgresql_query -------------------------------------------------
  #
  # Ansible's exit_json(changed, query, query_list, statusmessage,
  # query_result, query_all_results, rowcount, execution_time_ms), with
  # failed:false backfilled by the controller after the module's kwargs -
  # hence its position. No msg on success. A statement that produced no
  # rows renders as {} (not []) in both query_result and
  # query_all_results: the module's fetch loop leaves query_result == []
  # and then explicitly replaces it with {}. Live-verified against real
  # ansible-core 2.19.11 + community.postgresql 4.2.0.

  private def query_result_for(sql : String) : JSON::Any
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => sql}))
  end

  it "postgresql_query select registers the full key order and no msg" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    result = query_result_for("SELECT 1 AS one, 'x'::text AS t")
    shape_keys(result).must_equal(["changed", "query", "query_list", "statusmessage",
                                   "query_result", "query_all_results", "rowcount", "execution_time_ms", "failed", "warnings"])
    result["changed"].as_bool.must_equal(false)
    result["query"].as_s.must_equal("SELECT 1 AS one, 'x'::text AS t")
    result["query_list"].as_a.map(&.as_s).must_equal(["SELECT 1 AS one, 'x'::text AS t"])
    result["statusmessage"].as_s.must_equal("SELECT 1")
    result["query_result"].as_a.map { |row| row.as_h["one"].as_i }.must_equal([1])
    result["query_all_results"].as_a.size.must_equal(1)
    result["rowcount"].as_i.must_equal(1)
    result["execution_time_ms"].as_a.size.must_equal(1)
    result["failed"].as_bool.must_equal(false)
    result["msg"]?.try(&.as_s).must_be_nil
  end

  it "postgresql_query DDL reports changed with an empty-dict result and a real command tag" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP TABLE IF EXISTS shape_pg_q"}))
    result = query_result_for("CREATE TABLE shape_pg_q (id int)")
    shape_keys(result).must_equal(["changed", "query", "query_list", "statusmessage",
                                   "query_result", "query_all_results", "rowcount", "execution_time_ms", "failed", "warnings"])
    result["changed"].as_bool.must_equal(true)
    result["statusmessage"].as_s.must_equal("CREATE TABLE")
    result["query_result"].as_h.must_be_empty
    result["query_all_results"].as_a.map { |entry| entry.as_h.size }.must_equal([0])
    result["rowcount"].as_i.must_equal(0)
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP TABLE shape_pg_q"}))
  end

  it "postgresql_query multi-statement list keeps per-statement results" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    result = PluginSpecHelper.run("postgresql_query",
      SHAPE_LOGIN.merge({"query" => %(["SELECT 1 AS a", "SELECT 2 AS b"])}))
    shape_keys(result).must_equal(["changed", "query", "query_list", "statusmessage",
                                   "query_result", "query_all_results", "rowcount", "execution_time_ms", "failed", "warnings"])
    result["query"].as_s.must_equal("SELECT 2 AS b")
    result["query_list"].as_a.map(&.as_s).must_equal(["SELECT 1 AS a", "SELECT 2 AS b"])
    result["query_all_results"].as_a.size.must_equal(2)
    result["rowcount"].as_i.must_equal(2)
    result["execution_time_ms"].as_a.size.must_equal(2)
  end

  it "postgresql_query row-affecting statements tag their row count" do
    skip "no PostgreSQL server at 127.0.0.1:35432" unless shape_postgres_reachable?
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP TABLE IF EXISTS shape_pg_q2"}))
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "CREATE TABLE shape_pg_q2 (id int)"}))
    inserted = query_result_for("INSERT INTO shape_pg_q2 VALUES (1), (2)")
    inserted["changed"].as_bool.must_equal(true)
    inserted["statusmessage"].as_s.must_equal("INSERT 0 2")
    updated = query_result_for("UPDATE shape_pg_q2 SET id = id + 1")
    updated["changed"].as_bool.must_equal(true)
    updated["statusmessage"].as_s.must_equal("UPDATE 2")
    deleted = query_result_for("DELETE FROM shape_pg_q2 WHERE id > 2")
    deleted["changed"].as_bool.must_equal(true)
    deleted["statusmessage"].as_s.must_equal("DELETE 1")
    PluginSpecHelper.run("postgresql_query", SHAPE_LOGIN.merge({"query" => "DROP TABLE shape_pg_q2"}))
  end
end

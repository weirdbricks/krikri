require "../minitest_helper"
require "socket"

# Live-server integration spec for postgresql_privs, driven through the
# real plugin binary (PluginSpecHelper) against a throwaway PostgreSQL at
# 127.0.0.1:15432 (same pattern as postgresql_live_spec.cr; pendings when
# no server is listening there).
#
# Regression for round 981082 (gmazoyer.peering_manager): the plugin used
# to reject perfectly legal identifiers through a
# "objs/roles/schema may only contain letters, digits, and underscores"
# allow-list - a hyphenated role name (`role: peering-manager`) granted
# USAGE on a schema failed, while real community.postgresql succeeds by
# quoting identifiers (pg_quote_identifier / psycopg identifier quoting).
# Now every identifier is quoted injection-safely instead of allow-listed,
# so hyphens, spaces, quotes and friends all work.
private def privs_postgres_reachable? : Bool
  sock = TCPSocket.new("127.0.0.1", 15432, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

PRIVS_POSTGRES_LOGIN = {
  "login_host"     => "127.0.0.1",
  "login_port"     => "15432",
  "login_user"     => "postgres",
  "login_password" => "rootpass",
}

private def run_privs(params : Hash(String, String)) : JSON::Any
  PluginSpecHelper.run("postgresql_privs", PRIVS_POSTGRES_LOGIN.merge(params))
end

# Setup/teardown statements run tolerantly: a REVOKE of a grant that was
# never made (or a DROP of a role still holding one) fails server-side and
# must not abort the test - the later statements sort the state out.
private def run_query_tolerant(query : String) : Nil
  PluginSpecHelper.run("postgresql_query", PRIVS_POSTGRES_LOGIN.merge({
    "login_db" => "postgres",
    "query"    => query,
  }))
end

private def public_schema_acl : String
  acl = PluginSpecHelper.run("postgresql_query", PRIVS_POSTGRES_LOGIN.merge({
    "login_db" => "postgres",
    "query"    => %(SELECT nspacl::text FROM pg_namespace WHERE nspname = 'public'),
  }))
  acl["query_result"].as_a[0]["nspacl"].as_s
end

describe "postgresql_privs against a real PostgreSQL server at 127.0.0.1:15432" do
  it "grants schema privileges to a hyphenated role (the peering_manager round divergence)" do
    skip "no PostgreSQL server at 127.0.0.1:15432" unless privs_postgres_reachable?
    run_query_tolerant(%(REVOKE USAGE ON SCHEMA public FROM "peering-manager"))
    run_query_tolerant(%(DROP ROLE IF EXISTS "peering-manager"))
    run_query_tolerant(%(CREATE ROLE "peering-manager" LOGIN))

    # The exact task shape from the bug report.
    grant = run_privs({
      "db"    => "postgres",
      "privs" => "USAGE",
      "type"  => "schema",
      "objs"  => "public",
      "role"  => "peering-manager",
    })
    grant["failed"]?.must_be_nil
    grant["changed"].as_bool.must_equal(true)

    # Idempotent repeat.
    repeat = run_privs({
      "db"    => "postgres",
      "privs" => "USAGE",
      "type"  => "schema",
      "objs"  => "public",
      "role"  => "peering-manager",
    })
    repeat["failed"]?.must_be_nil
    repeat["changed"].as_bool.must_equal(false)

    # nspacl is array text, so the quoted role name is itself escaped with
    # backslashes inside it - the grantee here is exactly the one hyphenated
    # role, quoted, not something the SQL broke apart.
    public_schema_acl.must_include(%q(\"peering-manager\"=U/))

    run_privs({
      "db"    => "postgres",
      "privs" => "USAGE",
      "type"  => "schema",
      "objs"  => "public",
      "role"  => "peering-manager",
      "state" => "absent",
    })
    run_query_tolerant(%(DROP ROLE IF EXISTS "peering-manager"))
  end

  it "quotes identifier text that would terminate a bare identifier (injection safety, live)" do
    skip "no PostgreSQL server at 127.0.0.1:15432" unless privs_postgres_reachable?
    # A role name carrying a double quote and a hyphen - the quote must
    # end up doubled inside the quoted identifier, not terminate it.
    nasty_role_sql = %q("ro""le-x")
    run_query_tolerant(%(REVOKE USAGE ON SCHEMA public FROM #{nasty_role_sql}))
    run_query_tolerant(%(DROP ROLE IF EXISTS #{nasty_role_sql}))
    run_query_tolerant(%(CREATE ROLE #{nasty_role_sql} LOGIN))

    grant = run_privs({
      "db"    => "postgres",
      "privs" => "USAGE",
      "type"  => "schema",
      "objs"  => "public",
      "role"  => %q(ro"le-x),
    })
    grant["failed"]?.must_be_nil
    grant["changed"].as_bool.must_equal(true)

    # The stored ACL entry proves the GRANT ran against the one intended
    # role - a broken quote would have failed the statement outright.
    # Array-text escaping: the role's own quoted form ("ro""le-x") is
    # backslash-escaped inside nspacl's {} list.
    public_schema_acl.must_include(%q(\"ro\"\"le-x\"=U/))

    run_privs({
      "db"    => "postgres",
      "privs" => "USAGE",
      "type"  => "schema",
      "objs"  => "public",
      "role"  => %q(ro"le-x),
      "state" => "absent",
    })
    run_query_tolerant(%(DROP ROLE IF EXISTS #{nasty_role_sql}))
  end

  it "still fails a schema grant for a nonexistent role with fail_on_role default" do
    skip "no PostgreSQL server at 127.0.0.1:15432" unless privs_postgres_reachable?
    grant = run_privs({
      "db"    => "postgres",
      "privs" => "USAGE",
      "type"  => "schema",
      "objs"  => "public",
      "role"  => "no-such-role-here",
    })
    grant["failed"].as_bool.must_equal(true)
    grant["msg"].as_s.must_include("Role 'no-such-role-here' does not exist")
  end
end

require "../spec_helper"
require "socket"

# Live-server integration spec for postgresql_query and postgresql_user,
# driven through the real plugin binaries (PluginSpecHelper) against a
# throwaway PostgreSQL at 127.0.0.1:15432 - the same pattern cli_spec.cr's
# "requires a real server at 127.0.0.1:15432" smoke test uses. With no
# server listening there, the spec pendings instead of failing.
#
# Covers two real bugs found by an ad-hoc CLI comparison sweep against
# real ansible (2026-09-13):
#
# 1. postgresql_query flattened a multi-row SELECT's result set down to
#    only its first row (and returned it as a bare object instead of an
#    array) - silent data loss; and integer columns came back as JSON
#    strings instead of native numbers.
#
# 2. postgresql_user unconditionally ran ALTER ROLE ... PASSWORD when a
#    password: was given, so every repeat call reported changed: true;
#    real Ansible diffs the desired password against the stored
#    pg_authid.rolpassword verifier and no-ops when they match.
private def postgres_reachable? : Bool
  sock = TCPSocket.new("127.0.0.1", 15432, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

POSTGRES_LOGIN = {
  "login_host"     => "127.0.0.1",
  "login_port"     => "15432",
  "login_user"     => "postgres",
  "login_password" => "rootpass",
}

describe "postgresql_query/postgresql_user against a real PostgreSQL server at 127.0.0.1:15432" do
  describe "postgresql_query" do
    it "returns the full multi-row result set as an array of typed row objects" do
      pending! "no PostgreSQL server at 127.0.0.1:15432" unless postgres_reachable?
      PluginSpecHelper.run("postgresql_query", POSTGRES_LOGIN.merge({
        "login_db" => "postgres",
        "query"    => "DROP TABLE IF EXISTS krikri_spec_rows",
      }))
      PluginSpecHelper.run("postgresql_query", POSTGRES_LOGIN.merge({
        "login_db" => "postgres",
        "query"    => "CREATE TABLE krikri_spec_rows (id INT PRIMARY KEY, name VARCHAR(50))",
      }))
      insert = PluginSpecHelper.run("postgresql_query", POSTGRES_LOGIN.merge({
        "login_db" => "postgres",
        "query"    => "INSERT INTO krikri_spec_rows VALUES (1, 'alice'), (2, 'bob')",
      }))
      insert["changed"].as_bool.should be_true

      select_result = PluginSpecHelper.run("postgresql_query", POSTGRES_LOGIN.merge({
        "login_db" => "postgres",
        "query"    => "SELECT * FROM krikri_spec_rows ORDER BY id",
      }))

      select_result["rowcount"].as_i.should eq(2)
      rows = select_result["query_result"].as_a
      rows.size.should eq(2)
      # Native JSON integers - not "1"/"2" strings (psycopg2 hands real
      # Ansible native ints).
      rows[0]["id"].as_i.should eq(1)
      rows[0]["name"].as_s.should eq("alice")
      rows[1]["id"].as_i.should eq(2)
      rows[1]["name"].as_s.should eq("bob")
      # query_all_results: one row-list per statement, same rows.
      all_rows = select_result["query_all_results"].as_a[0].as_a
      all_rows.size.should eq(2)
      all_rows[1]["id"].as_i.should eq(2)
      # SELECTs never report changed (the real module's command-tag rule).
      select_result["changed"].as_bool.should be_false

      PluginSpecHelper.run("postgresql_query", POSTGRES_LOGIN.merge({
        "login_db" => "postgres",
        "query"    => "DROP TABLE krikri_spec_rows",
      }))
    end

    it "coerces numeric column types to native JSON numbers" do
      pending! "no PostgreSQL server at 127.0.0.1:15432" unless postgres_reachable?
      result = PluginSpecHelper.run("postgresql_query", POSTGRES_LOGIN.merge({
        "login_db" => "postgres",
        "query"    => "SELECT 7::int AS i, 8::bigint AS b, 2.5::float8 AS f, 1.23::numeric AS n",
      }))
      row = result["query_result"].as_a[0]
      row["i"].as_i.should eq(7)
      row["b"].as_i.should eq(8)
      row["f"].as_f.should eq(2.5)
      # Real module's convert_to_supported: Decimal -> float, i.e. a
      # native JSON number (not the string "1.23").
      row["n"].as_f.should eq(1.23)
    end
  end

  describe "postgresql_user" do
    it "reports changed: false on an unchanged repeat call with the same password" do
      pending! "no PostgreSQL server at 127.0.0.1:15432" unless postgres_reachable?
      created = PluginSpecHelper.run("postgresql_user", POSTGRES_LOGIN.merge({
        "name"     => "krikri_spec_role",
        "password" => "s3cretpw",
      }))
      created["changed"].as_bool.should be_true

      repeat = PluginSpecHelper.run("postgresql_user", POSTGRES_LOGIN.merge({
        "name"     => "krikri_spec_role",
        "password" => "s3cretpw",
      }))
      # The core idempotency regression: this used to be true on every
      # call because the plugin never compared against the stored
      # pg_authid.rolpassword verifier.
      repeat["changed"].as_bool.should be_false

      changed = PluginSpecHelper.run("postgresql_user", POSTGRES_LOGIN.merge({
        "name"     => "krikri_spec_role",
        "password" => "otherpw",
      }))
      changed["changed"].as_bool.should be_true

      dropped = PluginSpecHelper.run("postgresql_user", POSTGRES_LOGIN.merge({
        "name"  => "krikri_spec_role",
        "state" => "absent",
      }))
      dropped["changed"].as_bool.should be_true
    end
  end
end

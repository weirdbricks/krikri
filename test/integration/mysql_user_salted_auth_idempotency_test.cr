require "../minitest_helper"
require "socket"
require "../../src/krikri/plugin_helpers/mysql_salted_hash"

# Regression specs for the mysql_user server-side comparison reads: every
# idempotency check the plugin makes does the comparison entirely
# server-side (`SELECT plugin = ?` / `SELECT authentication_string = ?`),
# but those `=` expressions come back on the wire with MySQL's LONGLONG
# column type, and the vendored mysql shard has no read(Int32) at all - an
# `as: Int32` cast raised ColumnTypeMismatchError that each check's rescue
# swallowed as "doesn't match", so every warm run re-issued the
# CREATE/ALTER (wiggels.snipeit's `Create snipeit user` task with
# plugin: caching_sha2_password + plugin_auth_string: + salt:, round
# 1700000; the native-password path regressed the same way). The casts now
# read Int64; these specs pin the warm-run convergence the bug broke.
#
# The salt path additionally pins the stored authentication_string byte
# for byte against Krikri::PluginHelpers::MysqlSaltedHash (the deterministic
# `$A$005$<salt><digest>` form real's user.py compares with) - live-
# verified against ansible.mysql 5.2.0 on MySQL 8.0: real's warm run
# reports ok with the same hash bytes stored via `AS 0x...`.
#
# Specs skip when no MySQL/MariaDB server is up on the documented test
# ports; the salt path further skips servers without caching_sha2_password
# (MariaDB), decided by a throwaway probe the server itself judges.

private SERVERS = [
  {host: "127.0.0.1", port: 33306, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "krikri"},
  {host: "127.0.0.1", port: 33307, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "krikri"},
]

private SPEC_USER = "krikri_salt_probe"

private def daemon_reachable?(host : String, port : Int32) : Bool
  sock = TCPSocket.new(host, port, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

private def login_args(server : NamedTuple(host: String, port: Int32, password: String)) : Hash(String, String)
  {
    "login_host"     => server[:host],
    "login_port"     => server[:port].to_s,
    "login_user"     => "root",
    "login_password" => server[:password],
  }
end

private def mysql_query(server : NamedTuple(host: String, port: Int32, password: String), sql : String) : JSON::Any
  PluginSpecHelper.run("mysql_query", {"query" => sql}.merge(login_args(server)))
end

private def failed?(result : JSON::Any) : Bool
  result["failed"]?.try(&.as_bool?) || false
end

private def drop_spec_user(server : NamedTuple(host: String, port: Int32, password: String)) : Nil
  mysql_query(server, "DROP USER IF EXISTS `#{SPEC_USER}`@`%`")
end

private def caching_sha2_available?(server : NamedTuple(host: String, port: Int32, password: String)) : Bool
  probe = mysql_query(server, "CREATE USER `#{SPEC_USER}`@`%` IDENTIFIED WITH caching_sha2_password")
  available = !failed?(probe)
  drop_spec_user(server)
  available
end

private def run_salted_user(server, password : String, salt : String) : JSON::Any
  PluginSpecHelper.run("mysql_user", {
    "name"               => SPEC_USER,
    "host"               => "%",
    "plugin"             => "caching_sha2_password",
    "plugin_auth_string" => password,
    "salt"               => salt,
  }.merge(login_args(server)))
end

describe "mysql_user server-side comparison reads" do
  it "keeps caching_sha2_password + salt idempotent and stores the deterministic hash" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      drop_spec_user(server)
      skip "server has no caching_sha2_password" unless caching_sha2_available?(server)

      password = "krikri-salt-pass"
      salt = "krikri0123456789abcd"

      created = run_salted_user(server, password, salt)
      failed?(created).must_equal(false)
      created["changed"].as_bool.must_equal(true)
      created["msg"].as_s.must_equal("User added")

      warm = run_salted_user(server, password, salt)
      failed?(warm).must_equal(false)
      warm["changed"].as_bool.must_equal(false)
      warm["msg"].as_s.must_equal("User unchanged")

      row = mysql_query(server, "SELECT (plugin = 'caching_sha2_password') AND (authentication_string = '#{Krikri::PluginHelpers::MysqlSaltedHash.hash(password, salt)}') AS ok FROM mysql.user WHERE User = '#{SPEC_USER}' AND Host = '%'")
      row["query_result"][0][0]["ok"].as_i64.must_equal(1)

      # A different salt is a real change: the update path (ALTER ... AS 0x)
      # must fire - and then converge again.
      rotated = run_salted_user(server, password, "krikri9876543210zyxw")
      failed?(rotated).must_equal(false)
      rotated["changed"].as_bool.must_equal(true)
      rotated["msg"].as_s.must_equal("User updated")

      warm_again = run_salted_user(server, password, "krikri9876543210zyxw")
      failed?(warm_again).must_equal(false)
      warm_again["changed"].as_bool.must_equal(false)

      row = mysql_query(server, "SELECT authentication_string = '#{Krikri::PluginHelpers::MysqlSaltedHash.hash(password, "krikri9876543210zyxw")}' AS ok FROM mysql.user WHERE User = '#{SPEC_USER}' AND Host = '%'")
      row["query_result"][0][0]["ok"].as_i64.must_equal(1)

      drop_spec_user(server)
    end
  end
end

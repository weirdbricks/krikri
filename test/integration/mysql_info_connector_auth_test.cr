require "../minitest_helper"
require "socket"

# Regression specs for the KNOWN_MISSING "MySQL driver gaps" mysql_info
# items: real reports the PYTHON connector it used (pymysql and its
# version) as connector_name/connector_version, and its users output
# carries each account's authentication_string read from mysql.user
# (live-verified against real 2.19.11 + community.mysql 5.0.2 on MySQL
# 8.4). krikri used to report "Unknown" for both connector facts and
# omitted authentication_string entirely.
#
# Both documented live-server conventions are exercised when up: the
# mysql:8.4 throwaway on 33306 and a MariaDB on 33307 - the
# authentication_string read needs the server-side LEFT() rewrite on
# MariaDB (LONGTEXT wire type) but not on MySQL 8, so both engines get
# covered. Specs skip when neither server runs.
private SERVERS = [
  {host: "127.0.0.1", port: 33306, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "krikri"},
  {host: "127.0.0.1", port: 33307, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "krikri"},
]

private PROBE_USER = "krikri_info_probe"

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

describe "mysql_info connector identity" do
  it "reports real's Python driver identity, not Unknown" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      result = PluginSpecHelper.run("mysql_info", {"filter" => "version"}.merge(login_args(server)))
      failed?(result).must_equal(false)
      result["connector_name"].as_s.must_equal("pymysql")
      # pymysql's own version string format (three dot-separated numbers).
      result["connector_version"].as_s.must_match(/^1\.1\.\d+$/)
    end
  end
end

describe "mysql_info users authentication_string" do
  it "reports authentication_string in users, empty for a passwordless account" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      mysql_query(server, "DROP USER IF EXISTS `#{PROBE_USER}`@`%`")
      created = mysql_query(server, "CREATE USER `#{PROBE_USER}`@`%`")
      skip "server refuses a passwordless CREATE USER" if failed?(created)

      result = PluginSpecHelper.run("mysql_info", {"filter" => "users"}.merge(login_args(server)))
      failed?(result).must_equal(false)

      attrs = result["users"]["%"][PROBE_USER]
      attrs["authentication_string"]?.wont_be_nil
      attrs["authentication_string"].as_s.must_equal("")

      # A hash-bearing account (root) carries a non-empty string.
      auth_strings = result["users"].as_h.values
        .flat_map(&.as_h.values)
        .map(&.as_h["authentication_string"].as_s)
      auth_strings.any? { |value| !value.empty? }.must_equal(true)

      mysql_query(server, "DROP USER IF EXISTS `#{PROBE_USER}`@`%`")
    end
  end

  it "does not add authentication_string to users_info entries (real keeps it in users only)" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      result = PluginSpecHelper.run("mysql_info", {"filter" => "users_info"}.merge(login_args(server)))
      failed?(result).must_equal(false)

      entries = result["users_info"].as_a
      (entries.size > 0).must_equal(true)
      entries.each do |entry|
        entry["authentication_string"]?.must_be_nil
      end
    end
  end
end

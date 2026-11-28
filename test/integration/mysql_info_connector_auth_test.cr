require "../minitest_helper"
require "socket"
require "../../src/krikri/plugin_helpers/mysql_connection"

# Regression specs for the KNOWN_MISSING "MySQL driver gaps" mysql_info
# items: Ansible reports the PYTHON connector it used (pymysql and its
# version) as connector_name/connector_version, and its users output
# carries each account's authentication_string read from mysql.user
# (live-verified against Ansible 2.19.11 + community.mysql 5.0.2 on MySQL
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
  PluginSpecHelper.mysql_server_at?(host, port)
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
  it "reports Ansible's Python driver identity, not Unknown" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      result = PluginSpecHelper.run("mysql_info", {"filter" => "version"}.merge(login_args(server)))
      failed?(result).must_equal(false)
      result["connector_name"].as_s.must_equal("pymysql")
      # Real reports the TARGET's pymysql VERSION[:3] (get_connector_version),
      # so the value follows that host's installed connector rather than a
      # constant of this engine's.
      result["connector_version"].as_s.must_match(/^\d+\.\d+\.\d+$/)
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

  it "does not add authentication_string to users_info entries (Ansible keeps it in users only)" do
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

# ansible.mysql's get_server_implementation warns right after a successful
# connection whenever SELECT VERSION() says MariaDB, and mysql_info reports
# that same detection as `server_engine`. It also resolves SHOW SLAVE HOSTS
# to MariaDB's SHOW REPLICA HOSTS - MariaDB rejects MySQL's SHOW REPLICAS
# with a syntax error, which is what made a plain mysql_info read fail.
describe "mysql_info MariaDB deprecation warning" do
  it "warns about the upcoming MariaDB support drop and names the MariaDB engine" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    mariadb_servers = servers.select do |server|
      version = mysql_query(server, "SELECT VERSION() AS v")
      version["query_result"][0][0]["v"].as_s.downcase.includes?("mariadb")
    end
    skip "no MariaDB server on 33307" if mariadb_servers.empty?

    mariadb_servers.each do |server|
      result = PluginSpecHelper.run("mysql_info", {"filter" => "slave_hosts"}.merge(login_args(server)))
      failed?(result).must_equal(false, result.to_json)
      result["server_engine"].as_s.must_equal("MariaDB")
      result["warnings"].as_a.map(&.as_s).must_equal([Krikri::PluginHelpers::MysqlConnection::MARIADB_WARNING])
      result["slave_hosts"].as_h.must_be_empty
    end
  end
end

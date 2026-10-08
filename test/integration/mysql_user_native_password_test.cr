require "../minitest_helper"
require "socket"

# Regression specs for the KNOWN_MISSING "MySQL driver gaps" mysql_user
# item: with no `plugin:` given, real community.mysql hashes the password
# itself and issues `CREATE/ALTER USER ... IDENTIFIED WITH
# mysql_native_password AS '<hash>'` - so on a server where that plugin is
# not loaded (MySQL 8.4+ ships it disabled by default) the server rejects
# the statement with error 1524 and the task fails with pymysql's
# `(1524, "Plugin '...' is not loaded")` msg shape, while on a server with
# the plugin loaded the account is created as a mysql_native_password
# account. krikri used to issue `IDENTIFIED BY` (server-default hashing)
# and succeeded everywhere. Live-verified against Ansible 2.19.11 +
# community.mysql 5.0.2 on MySQL 8.4.
#
# Both documented live-server conventions are exercised when up (the
# branch taken is decided by the server itself, never by version
# sniffing): the mysql:8.4 throwaway on 33306 takes the failure branch,
# a MariaDB on 33307 the success branch. Specs skip when neither runs.
private SERVERS = [
  {host: "127.0.0.1", port: 33306, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "krikri"},
  {host: "127.0.0.1", port: 33307, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "krikri"},
]

private PROBE_USER = "krikri_np_probe"
private SPEC_USER  = "krikri_np_spec"

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

# Whether the server accepts mysql_native_password at all - decided by
# letting the server judge a throwaway CREATE USER, the same
# attempt-and-reject way the plugin itself detects it (never by
# version-sniffing). Cleans up after itself either way.
private def native_plugin_available?(server : NamedTuple(host: String, port: Int32, password: String)) : Bool
  probe = mysql_query(server, "CREATE USER `#{PROBE_USER}`@`%` IDENTIFIED WITH mysql_native_password AS '*8D969EEF6ECAD3C29A3A675280E48AEDB4E0E2A0'")
  available = !failed?(probe)
  mysql_query(server, "DROP USER `#{PROBE_USER}`@`%`")
  available
end

private def drop_spec_user(server : NamedTuple(host: String, port: Int32, password: String)) : Nil
  mysql_query(server, "DROP USER IF EXISTS `#{SPEC_USER}`@`%`")
end

describe "mysql_user default-plugin password path" do
  # Both examples share one account on the live server (port 33307):
  # under -p N they race, so run them one at a time.
  serial!
  it "matches Ansible's create behavior (native-password account, or Ansible's 1524 failure)" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      drop_spec_user(server)

      if native_plugin_available?(server)
        result = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-pass",
        }.merge(login_args(server)))
        failed?(result).must_equal(false)
        result["msg"].as_s.must_equal("User added")

        # The account must be a mysql_native_password account whose hash is
        # the server-computed native hash of the given password - what real
        # stores, not the server default plugin's hash.
        row = mysql_query(server, "SELECT (plugin = 'mysql_native_password') AND (CONCAT('*', UCASE(SHA1(UNHEX(SHA1('krikri-np-pass'))))) = authentication_string) AS ok FROM mysql.user WHERE User = '#{SPEC_USER}' AND Host = '%'")
        row["query_result"][0][0]["ok"].as_i64.must_equal(1)

        # And the usual idempotency still holds.
        again = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-pass",
        }.merge(login_args(server)))
        again["changed"].as_bool.must_equal(false)
      else
        result = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-pass",
        }.merge(login_args(server)))
        failed?(result).must_equal(true)
        # Ansible's fail_json(msg=to_native(e)) passes pymysql's str(Exception)
        # through: the (errno, "message") tuple form.
        result["msg"].as_s.must_equal(%((1524, "Plugin 'mysql_native_password' is not loaded")))
        # The failed CREATE must not have left the account behind.
        row = mysql_query(server, "SELECT COUNT(*) AS c FROM mysql.user WHERE User = '#{SPEC_USER}'")
        row["query_result"][0][0]["c"].as_i64.must_equal(0)
      end

      drop_spec_user(server)
    end
  end

  it "matches Ansible's password-update behavior on an existing account" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL/MariaDB server on 33306/33307" if servers.empty?

    servers.each do |server|
      drop_spec_user(server)

      if native_plugin_available?(server)
        PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-one",
        }.merge(login_args(server)))

        updated = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-two",
        }.merge(login_args(server)))
        failed?(updated).must_equal(false)
        updated["changed"].as_bool.must_equal(true)
        # Real's user_mod wording for the ALTER it issues on a current
        # server (old_user_mgmt false) - live-verified MySQL 8.0.
        updated["msg"].as_s.must_equal("Password updated (new style)")

        row = mysql_query(server, "SELECT (plugin = 'mysql_native_password') AND (CONCAT('*', UCASE(SHA1(UNHEX(SHA1('krikri-np-two'))))) = authentication_string) AS ok FROM mysql.user WHERE User = '#{SPEC_USER}' AND Host = '%'")
        row["query_result"][0][0]["ok"].as_i64.must_equal(1)

        same = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-two",
        }.merge(login_args(server)))
        same["changed"].as_bool.must_equal(false)
      else
        # A server with mysql_native_password not loaded is MySQL 8.4+,
        # where caching_sha2_password is available to seed a non-native
        # account (the same setup Ansible's own update path fails on).
        seeded = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "plugin" => "caching_sha2_password",
        }.merge(login_args(server)))
        skip "cannot seed a non-native account on this server" if failed?(seeded)

        updated = PluginSpecHelper.run("mysql_user", {
          "name" => SPEC_USER, "host" => "%", "password" => "krikri-np-two",
        }.merge(login_args(server)))
        failed?(updated).must_equal(true)
        updated["msg"].as_s.must_equal(%((1524, "Plugin 'mysql_native_password' is not loaded")))

        # The failed ALTER must have left the account untouched.
        row = mysql_query(server, "SELECT plugin = 'caching_sha2_password' AND LENGTH(authentication_string) = 0 AS ok FROM mysql.user WHERE User = '#{SPEC_USER}' AND Host = '%'")
        row["query_result"][0][0]["ok"].as_i64.must_equal(1)
      end

      drop_spec_user(server)
    end
  end
end

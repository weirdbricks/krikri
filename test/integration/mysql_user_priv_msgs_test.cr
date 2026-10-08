require "../minitest_helper"
require "socket"

# Regression specs for the MySQL 8.x mysql_user verification round (vs
# Ansible 2.19.11 + community.mysql 5.0.2, live against podman mysql:8.0
# on 13380 and mysql:8.4 on 13384, root password overridable with
# KRIKRI_MYSQL_ROOT_PASS): the update-path success msgs real's user_mod
# produces are branch-specific - "Password updated (new style)" for the
# ALTER it issues, the *unchanged* default for its plugin/auth ALTER
# (changed=true but msg never touched), and three different wordings from
# its privilege loops ("Privileges updated" / "New privileges granted" /
# "Privileges updated: granted [...], revoked [...]") - plus the
# privileges_grant failure wrapper for a GRANT on a missing table, and the
# MySQL 8.4 behavior where real's leaked grant_option flag makes a bare
# `REVOKE GRANT OPTION` hit error 1141 and fail the task (8.0 tolerates
# the same statement). Specs skip when neither server runs.
private SERVERS = [
  {host: "127.0.0.1", port: 13380, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpw"},
  {host: "127.0.0.1", port: 13384, password: ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpw"},
]

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

private def mysql_user(server : NamedTuple(host: String, port: Int32, password: String), params : Hash(String, String)) : JSON::Any
  PluginSpecHelper.run("mysql_user", params.merge(login_args(server)))
end

private def failed?(result : JSON::Any) : Bool
  result["failed"]?.try(&.as_bool?) || false
end

private def setup(server : NamedTuple(host: String, port: Int32, password: String), sqls : Array(String)) : Nil
  sqls.each { |sql| mysql_query(server, sql) }
end

describe "mysql_user update-path msgs vs real" do
  it "reports Password updated (new style) on a password ALTER" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup(server, ["DROP USER IF EXISTS `krikri_pm_pw`@`localhost`",
                     "CREATE USER `krikri_pm_pw`@`localhost` IDENTIFIED BY 'one'"])
      result = mysql_user(server, {"name" => "krikri_pm_pw", "host" => "localhost", "password" => "two"})
      if failed?(result)
        # A server without mysql_native_password loaded (MySQL 8.4 default)
        # rejects the ALTER both engines issue - same 1524 shape.
        result["msg"].as_s.must_equal(%((1524, "Plugin 'mysql_native_password' is not loaded")))
      else
        result["changed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal("Password updated (new style)")
        result["password_changed"].as_bool.must_equal(true)
      end
      setup(server, ["DROP USER `krikri_pm_pw`@`localhost`"])
    end
  end

  it "leaves the User unchanged default msg on a plugin/auth ALTER" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup(server, ["DROP USER IF EXISTS `krikri_pm_pl`@`localhost`"])
      first = mysql_user(server, {"name" => "krikri_pm_pl", "host" => "localhost",
                                  "plugin" => "caching_sha2_password", "plugin_auth_string" => "one"})
      failed?(first).must_equal(false)
      first["msg"].as_s.must_equal("User added")

      second = mysql_user(server, {"name" => "krikri_pm_pl", "host" => "localhost",
                                   "plugin" => "caching_sha2_password", "plugin_auth_string" => "two"})
      failed?(second).must_equal(false)
      second["changed"].as_bool.must_equal(true)
      second["msg"].as_s.must_equal("User unchanged")
      setup(server, ["DROP USER `krikri_pm_pl`@`localhost`"])
    end
  end

  it "reports the privilege-loop wordings for grant, revoke and replace" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup(server, ["CREATE DATABASE IF NOT EXISTS `krikri_pm_db1`",
                     "CREATE DATABASE IF NOT EXISTS `krikri_pm_db2`",
                     "DROP USER IF EXISTS `krikri_pm_pr`@`localhost`",
                     "CREATE USER `krikri_pm_pr`@`localhost` IDENTIFIED BY 'x'",
                     "GRANT SELECT ON `krikri_pm_db1`.* TO `krikri_pm_pr`@`localhost`"])

      appended = mysql_user(server, {"name" => "krikri_pm_pr", "host" => "localhost",
                                     "priv" => "krikri_pm_db1.*:SELECT,INSERT", "append_privs" => "true"})
      failed?(appended).must_equal(false)
      appended["changed"].as_bool.must_equal(true)
      appended["msg"].as_s.must_equal("Privileges updated: granted ['INSERT'], revoked []")

      setup(server, ["GRANT INSERT ON `krikri_pm_db2`.* TO `krikri_pm_pr`@`localhost`"])
      replaced = mysql_user(server, {"name" => "krikri_pm_pr", "host" => "localhost",
                                     "priv" => "krikri_pm_db1.*:SELECT,INSERT", "append_privs" => "false"})
      failed?(replaced).must_equal(false)
      replaced["changed"].as_bool.must_equal(true)
      replaced["msg"].as_s.must_equal("Privileges updated")

      fresh = mysql_user(server, {"name" => "krikri_pm_new", "host" => "localhost",
                                  "priv" => "krikri_pm_db1.*:SELECT"})
      failed?(fresh).must_equal(false)
      fresh["msg"].as_s.must_equal("User added")

      setup(server, ["DROP USER IF EXISTS `krikri_pm_new`@`localhost`",
                     "DROP USER `krikri_pm_pr`@`localhost`",
                     "DROP DATABASE IF EXISTS `krikri_pm_db1`",
                     "DROP DATABASE IF EXISTS `krikri_pm_db2`"])
    end
  end

  it "wraps a failed GRANT in real's privileges_grant error shape" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup(server, ["CREATE DATABASE IF NOT EXISTS `krikri_pm_g`",
                     "DROP USER IF EXISTS `krikri_pm_gt`@`localhost`",
                     "CREATE USER `krikri_pm_gt`@`localhost` IDENTIFIED BY 'x'"])
      result = mysql_user(server, {"name" => "krikri_pm_gt", "host" => "localhost",
                                   "priv" => "krikri_pm_g.nosuchtable:SELECT"})
      failed?(result).must_equal(true)
      result["msg"].as_s.must_equal(
        "Error granting privileges, invalid priv string: SELECT , params: ('krikri_pm_gt', 'localhost'), " \
        "query: GRANT SELECT ON `krikri_pm_g`.`nosuchtable` TO %s@%s , " \
        "exception: (1146, \"Table 'krikri_pm_g.nosuchtable' doesn't exist\").")
      setup(server, ["DROP USER `krikri_pm_gt`@`localhost`",
                     "DROP DATABASE IF EXISTS `krikri_pm_g`"])
    end
  end

  it "matches real's leaked grant-option revoke outcome per server" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup(server, ["CREATE DATABASE IF NOT EXISTS `krikri_pm_d1`",
                     "CREATE DATABASE IF NOT EXISTS `krikri_pm_d3`",
                     "DROP USER IF EXISTS `krikri_pm_go`@`localhost`",
                     "CREATE USER `krikri_pm_go`@`localhost` IDENTIFIED BY 'x'",
                     "GRANT SELECT ON `krikri_pm_d1`.* TO `krikri_pm_go`@`localhost` WITH GRANT OPTION",
                     "GRANT INSERT ON `krikri_pm_d3`.* TO `krikri_pm_go`@`localhost`"])
      result = mysql_user(server, {"name" => "krikri_pm_go", "host" => "localhost",
                                   "priv" => "krikri_pm_d1.*:SELECT", "append_privs" => "false"})
      if failed?(result)
        # MySQL 8.4: real's leaked grant_option flag makes the db3 revoke
        # carry REVOKE GRANT OPTION, which this server rejects with 1141.
        result["msg"].as_s.must_equal(
          "(1141, \"There is no such grant defined for user 'krikri_pm_go' on host 'localhost'\")")
      else
        # MySQL 8.0 (and MariaDB): the same statement is tolerated, the
        # replace completes and the intersect branch's wording wins.
        result["changed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal("Privileges updated: granted [], revoked ['GRANT']")
      end
      setup(server, ["DROP USER `krikri_pm_go`@`localhost`",
                     "DROP DATABASE IF EXISTS `krikri_pm_d1`",
                     "DROP DATABASE IF EXISTS `krikri_pm_d3`"])
    end
  end
end

require "../minitest_helper"
require "socket"

# Regression spec for round 4310000's residual leaf (live vs Ansible
# 2.19.11 + community.mysql on podman mysql:8.0/8.4): with append_privs:
# true, re-granting a privilege the account already effectively holds is
# a server-side no-op, and real books changed=false anyway - its user_mod
# privilege branch sets only the msg while planning, and decides changed
# by comparing SHOW GRANTS from before the loop with a fresh one after
# executing (`changed = changed or (curr_priv != after_priv)`). The
# everyday shape: the spec's desired *.*:USAGE is always "missing" from
# an account holding other global privileges (MySQL only surfaces the
# baseline USAGE row when nothing else is granted), so a GRANT USAGE is
# planned on every run, executes fine, grants nothing, and real reports
# changed=false with the "Privileges updated: granted ['USAGE'], revoked
# []" msg. krikri used to book changed=true from the non-empty plan.
# Specs skip when neither server runs (same convention as
# mysql_user_priv_msgs_test.cr).
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

private def grants(server : NamedTuple(host: String, port: Int32, password: String), user : String) : String
  mysql_query(server, "SHOW GRANTS FOR #{user}@'localhost'")["query_result"]
    .as_a.map { |row| row.as_a.first.as_h.values.first.as_s }.join("\n")
end

# '*3DB...' is mysql_native_password's hash of "mp-pw" (same literal the
# podman-diff matrix harness created its setup accounts with). Statements
# go one per mysql_query call - the plugin driver runs single statements
# only.
private def setup_user(server : NamedTuple(host: String, port: Int32, password: String), user : String, extra_grant : String?) : Nil
  mysql_query(server, "DROP USER IF EXISTS #{user}@'localhost'")
  mysql_query(server, "CREATE USER #{user}@'localhost' IDENTIFIED WITH mysql_native_password AS '*3DB7D6777ABAFC9F69390438AA4E5ABFB5BDE569'")
  mysql_query(server, extra_grant) if extra_grant
end

describe "mysql_user append_privs no-op changed detection vs real" do
  it "books changed=false when append_privs re-grants only an already-held no-op privilege" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup_user(server, "mpapna", "GRANT DELETE ON *.* TO mpapna@'localhost'")
      result = mysql_user(server, {
        "name"         => "mpapna",
        "host"         => "localhost",
        "priv"         => "*.*:USAGE",
        "append_privs" => "true",
        "state"        => "present",
      })
      result["changed"].as_bool.must_equal false
      result["msg"].as_s.must_equal "Privileges updated: granted ['USAGE'], revoked []"
      grants(server, "mpapna").includes?("DELETE").must_equal true
    end
  end

  it "still books changed=true when the appended grant actually adds privileges" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup_user(server, "mpapnb", nil)
      result = mysql_user(server, {
        "name"         => "mpapnb",
        "host"         => "localhost",
        "priv"         => "*.*:SELECT",
        "append_privs" => "true",
        "state"        => "present",
      })
      result["changed"].as_bool.must_equal true
      grants(server, "mpapnb").includes?("SELECT").must_equal true
    end
  end

  it "books changed=false for the USAGE re-grant on an ALL PRIVILEGES + GRANT OPTION account" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup_user(server, "mpapnc", "GRANT ALL PRIVILEGES ON *.* TO mpapnc@'localhost' WITH GRANT OPTION")
      result = mysql_user(server, {
        "name"         => "mpapnc",
        "host"         => "localhost",
        "priv"         => "*.*:USAGE",
        "append_privs" => "true",
        "state"        => "present",
      })
      result["changed"].as_bool.must_equal false
      result["msg"].as_s.must_equal "Privileges updated: granted ['USAGE'], revoked []"
    end
  end

  it "keeps check mode changed=true for a planned no-op append (real's check-mode branch)" do
    servers = SERVERS.select { |server| daemon_reachable?(server[:host], server[:port]) }
    skip "no MySQL server on 13380/13384" if servers.empty?

    servers.each do |server|
      setup_user(server, "mpapnd", "GRANT DELETE ON *.* TO mpapnd@'localhost'")
      result = mysql_user(server, {
        "name"                => "mpapnd",
        "host"                => "localhost",
        "priv"                => "*.*:USAGE",
        "append_privs"        => "true",
        "state"               => "present",
        "_ansible_check_mode" => "true",
      })
      result["changed"].as_bool.must_equal true
      grants(server, "mpapnd").includes?("DELETE").must_equal true
    end
  end
end

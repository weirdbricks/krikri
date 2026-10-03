require "../minitest_helper"

# Regression spec for the ad-hoc CLI sweep (2026-09-13): a brand-new create
# used to report "Updated user X@H" - real community.mysql.mysql_user says
# "User added" when the account genuinely didn't exist (its own user_add
# branch) - and, live-verified against real 2.19.11 + community.mysql
# 5.0.2 on MySQL 8.4, the wording real also uses in check mode. The
# update/idempotent wording ("User updated" / "User unchanged") and the
# absent wording ("User deleted" / "User doesn't exist") match real too;
# see mysql_result_shape_test.cr for the registered-result shape.
# Needs a real
# MySQL/MariaDB server, same convention as the other live-server specs.
private HOST = "127.0.0.1"
private PORT = 13306

private def daemon_reachable?(host : String, port : Int32) : Bool
  sock = TCPSocket.new(host, port, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

describe "mysql_user create-vs-update msg" do
  it "says \"User added\" on a brand-new create, not \"Updated user\"" do
    skip "no MySQL/MariaDB server at #{HOST}:#{PORT}" unless daemon_reachable?(HOST, PORT)

    result = PluginSpecHelper.run("mysql_user", {
      "name"           => "krikri-spec-user",
      "host"           => "%",
      "password"       => "krikri-spec-pass",
      "login_host"     => HOST,
      "login_port"     => PORT.to_s,
      "login_user"     => "root",
      "login_password" => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("User added")

    result = PluginSpecHelper.run("mysql_user", {
      "name"           => "krikri-spec-user",
      "host"           => "%",
      "password"       => "krikri-spec-pass",
      "login_host"     => HOST,
      "login_port"     => PORT.to_s,
      "login_user"     => "root",
      "login_password" => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
    })
    result["changed"].as_bool.must_equal(false)

    PluginSpecHelper.run("mysql_user", {
      "name"           => "krikri-spec-user",
      "host"           => "%",
      "state"          => "absent",
      "login_host"     => HOST,
      "login_port"     => PORT.to_s,
      "login_user"     => "root",
      "login_password" => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
    })
  end
end

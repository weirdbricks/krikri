require "../minitest_helper"
require "socket"

# Regression spec for the ad-hoc CLI sweep (2026-09-13): a brand-new create
# used to report "Updated user X@H" - real community.mysql.mysql_user says
# "User added" when the account genuinely didn't exist (its own user_add
# branch) - and, live-verified against Ansible 2.19.11 + community.mysql
# 5.0.2 on MySQL 8.4, the wording Ansible also uses in check mode. The
# idempotent wording ("User unchanged") and the absent wording ("User
# deleted" / "User doesn't exist") match real too; the update-path wording
# is branch-specific ("Password updated (new style)", the privilege-loop
# msgs - see mysql_user_priv_msgs_test.cr);
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

    # With no `plugin:` given the create now goes through Ansible's
    # mysql_native_password default-plugin path (see
    # mysql_user_native_password_test.cr): on a server where that plugin
    # is not loaded (MySQL 8.4+) the task fails with Ansible's 1524 msg and
    # no account exists, so the wording is pinned in check mode instead
    # (which is where real produces the same "User added" without
    # touching the server).
    probe = PluginSpecHelper.run("mysql_user", {
      "name"           => "krikri-spec-user",
      "host"           => "%",
      "password"       => "krikri-spec-pass",
      "login_host"     => HOST,
      "login_port"     => PORT.to_s,
      "login_user"     => "root",
      "login_password" => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
    })

    if probe["failed"]?.try(&.as_bool?)
      check_mode = PluginSpecHelper.run("mysql_user", {
        "name"                => "krikri-spec-user",
        "host"                => "%",
        "password"            => "krikri-spec-pass",
        "_ansible_check_mode" => "true",
        "login_host"          => HOST,
        "login_port"          => PORT.to_s,
        "login_user"          => "root",
        "login_password"      => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
      })
      check_mode["changed"].as_bool.must_equal(true)
      check_mode["msg"].as_s.must_equal("User added")
      check_mode["password_changed"].raw.must_be_nil
    else
      probe["msg"].as_s.must_equal("User added")

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
    end

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

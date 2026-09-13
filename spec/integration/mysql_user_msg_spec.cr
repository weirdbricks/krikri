require "../spec_helper"

# Regression spec for the ad-hoc CLI sweep (2026-09-13): a brand-new create
# used to report "Updated user X@H" - real community.mysql.mysql_user says
# "User added" when the account genuinely didn't exist (its own user_add
# branch), which is also what its check_mode wording ("would be created")
# always implied. Update/idempotent wording is unchanged. Needs a real
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
    pending! "no MySQL/MariaDB server at #{HOST}:#{PORT}" unless daemon_reachable?(HOST, PORT)

    result = PluginSpecHelper.run("mysql_user", {
      "name"           => "krikri-spec-user",
      "host"           => "%",
      "password"       => "krikri-spec-pass",
      "login_host"     => HOST,
      "login_port"     => PORT.to_s,
      "login_user"     => "root",
      "login_password" => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
    })

    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true
    result["msg"].as_s.should eq("User added")

    result = PluginSpecHelper.run("mysql_user", {
      "name"           => "krikri-spec-user",
      "host"           => "%",
      "password"       => "krikri-spec-pass",
      "login_host"     => HOST,
      "login_port"     => PORT.to_s,
      "login_user"     => "root",
      "login_password" => ENV["KRIKRI_MYSQL_ROOT_PASS"]? || "rootpass",
    })
    result["changed"].as_bool.should be_false

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

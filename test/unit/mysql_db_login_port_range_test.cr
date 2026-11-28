require "../minitest_helper"

# mysql_db.py:665-667 fails the task when login_port is outside 0-65535, in
# its own main() right after the empty-name exit - before the chdir, the
# state/target branches and any connect (issue #1975). The value reaches the
# module as an int, so a non-integer spelling never gets here (the argument
# spec rejects it); these cases pin the range itself and its position.
describe "mysql_db login_port range" do
  it "fails a login_port above the unix port range" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"       => "krikri_probe",
      "login_port" => "70000",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("login_port must be a valid unix port number (0-65535)")
  end

  it "fails a negative login_port" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"       => "krikri_probe",
      "login_port" => "-5",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("login_port must be a valid unix port number (0-65535)")
  end

  it "fails a login_port past Int64 the way real's unbounded int() reads it" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"       => "krikri_probe",
      "login_port" => "99999999999999",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("login_port must be a valid unix port number (0-65535)")
  end

  it "accepts both ends of the range" do
    {"0", "65535"}.each do |port|
      result = PluginSpecHelper.run("mysql_db", {
        "name"              => "krikri_probe",
        "login_port"        => port,
        "login_unix_socket" => "/nonexistent/krikri-issue-1975.sock",
      })

      result["msg"]?.try(&.as_s?).wont_equal("login_port must be a valid unix port number (0-65535)")
    end
  end

  it "fails on the port before the chdir and before the missing dump target" do
    # Real's main() reads login_port into the range check ahead of the chdir
    # block and ahead of the state branches, so the port message wins over
    # both (live-verified against ansible-core 2.21.6, ansible.mysql 5.2.0).
    chdir = PluginSpecHelper.run("mysql_db", {
      "name"       => "krikri_probe",
      "login_port" => "70000",
      "chdir"      => "/nonexistent/krikri-issue-1975",
    })
    chdir["msg"].as_s.must_equal("login_port must be a valid unix port number (0-65535)")

    dump = PluginSpecHelper.run("mysql_db", {
      "name"       => "krikri_probe",
      "login_port" => "70000",
      "state"      => "dump",
    })
    dump["msg"].as_s.must_equal("login_port must be a valid unix port number (0-65535)")
  end
end

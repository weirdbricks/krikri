require "../spec_helper"

# postgresql_db must reject an invalid `state` at argument-validation
# time, BEFORE any connection attempt - matching real's argument_spec
# (verified in the podman-diff harness, cases Q3/Q10: real reports
# "value of state must be one of: absent, dump, present, restore, got:
# ..." against a server that isn't even reachable, while this plugin
# used to connect first and fail on the unreachable server instead).
# No PostgreSQL server is needed or wanted here: the point is precisely
# that these failures happen without one.
describe "postgresql_db invalid-state validation order" do
  it "rejects an invalid state without attempting any connection" do
    result = PluginSpecHelper.run("postgresql_db", {
      "name"       => "krikri_db",
      "state"      => "krikri_state",
      "login_host" => "127.0.0.1",
      "login_port" => "13399",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq(
      "value of state must be one of: absent, dump, present, restore, got: krikri_state")
  end

  it "still defaults state to present (no state given fails on connection, not args)" do
    result = PluginSpecHelper.run("postgresql_db", {
      "name"       => "krikri_db",
      "login_host" => "127.0.0.1",
      "login_port" => "13399",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("value of state")
  end
end

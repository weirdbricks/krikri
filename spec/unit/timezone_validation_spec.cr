require "../spec_helper"

# Pins plugins/timezone.cr's argument-validation surface against real
# community.general.timezone's AnsibleModule setup (required_one_of
# hwclock/name, hwclock choices local/UTC with the rtc alias, unsupported
# params with the all-aliases parenthetical), live-diffed vs real
# ansible-playbook via the podman-diff timezone_edge_cases harness.
# Only the validation failures are pinned here - the backend paths touch
# the SPEC-RUNNING HOST's /etc/timezone, so they're covered by the
# podman-diff case alone.
describe "timezone plugin argument validation" do
  it "fails with no name and no hwclock (required_one_of)" do
    result = PluginSpecHelper.run("timezone", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("one of the following is required: hwclock, name")
  end

  it "fails an invalid hwclock choice" do
    result = PluginSpecHelper.run("timezone", {"hwclock" => "krikri_clock"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of hwclock must be one of: local, UTC, got: krikri_clock")
  end

  it "fails an invalid choice reached through the rtc alias" do
    result = PluginSpecHelper.run("timezone", {"rtc" => "krikri_clock"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of hwclock must be one of: local, UTC, got: krikri_clock")
  end

  it "rejects unsupported parameters with the all-aliases parenthetical" do
    result = PluginSpecHelper.run("timezone", {"name" => "Etc/UTC", "krikri_param" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.timezone) module: krikri_param. " \
                                 "Supported parameters include: hwclock, name (rtc).")
  end

  it "fails a nonexistent zone before touching any state (init-time verify)" do
    result = PluginSpecHelper.run("timezone", {"name" => "Krikri/Zone"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("given timezone \"Krikri/Zone\" is not available")
  end
end

require "../spec_helper"

describe "wait_for_connection plugin" do
  it "succeeds immediately, never reports changed" do
    # Real bug found benchmarking robertdebock.test_connection (round
    # 113): entirely unimplemented before, silently dropped. This
    # codebase's plugins already run ON the target over the exact
    # connection real Ansible's own module would otherwise be retrying
    # to establish, so by the time this plugin's own process runs at
    # all, that connection has already succeeded.
    result = PluginSpecHelper.run("wait_for_connection", {} of String => String)

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
  end

  it "accepts connect_timeout/sleep/timeout params without erroring" do
    result = PluginSpecHelper.run("wait_for_connection", {
      "connect_timeout" => "5", "sleep" => "1", "timeout" => "60",
    })

    result["failed"].as_bool.should be_false
  end
end

require "../spec_helper"

describe "wait_for_connection plugin" do
  it "succeeds immediately for a local connection, never reports changed" do
    # Real bug found benchmarking robertdebock.test_connection (round
    # 113): entirely unimplemented before, silently dropped.
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

  # PluginSpecHelper always configures {"host" => {"name" => "localhost",
  # ...}} - and BasePlugin#local_connection? treats the host NAME
  # "localhost" as authoritative over any ansible_connection: var (see
  # its own comment), so every case here is necessarily a LOCAL-
  # connection run; there is no way to exercise this plugin's real SSH
  # retry-until-connect loop through this unit-style helper.
  #
  # Real bug found via GROG.reboot's own "Reboot host" -> "Wait for
  # host" sequence: this plugin used to run the same way every other
  # module does - uploaded to and executed ON the target, over the
  # exact connection it exists to wait for. The instant a real reboot
  # actually took the SSH connection down, the upload itself failed
  # outright ("Plugin execution failed on remote") instead of
  # patiently retrying - defeating the module's entire purpose. Fixed
  # by making it controller-only (plugin_manager.cr's
  # CONTROLLER_ONLY_PLUGINS, also excluded from the play's own
  # up-front batch-upload pass) and retrying the connection attempt
  # itself via BasePlugin#remote_exec - live-verified end to end
  # against a disposable Docker+sshd target: sshd down at task start,
  # brought up mid-wait (succeeds, picks it up on the next retry) and,
  # separately, never brought up at all (fails at the configured
  # timeout:, bounded, not hanging). See ROLES_TESTED.md's GROG.reboot
  # row for the exact timings from that live verification.
end

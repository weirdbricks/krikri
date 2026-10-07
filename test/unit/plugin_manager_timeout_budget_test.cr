require "../minitest_helper"
require "../../src/krikri/plugin_manager"

# The task-level `timeout:` budget on the remote (ssh) path starts AFTER the
# plugin-binary upload (PluginManager.execute_remote_plugin_transport sets
# `started` once ensure_uploaded returned). Real's alarm covers its module
# transfer, but that module is ~180 KB while krikri's plugin is ~15 MB (cached
# on the host after the first upload): counting krikri's one-time upload
# failed a cold first task real passes on a slow link. Live-verified
# 2026-10-07 against ansible-core 2.19.11 over a 200 KB/s link,
# `command: echo hi` with `timeout: 2`: real ok in 0.9 s, krikri (upload
# counted) "Timed out after 2 second(s)" after 37 s.
#
# This pins the arithmetic seam of the exec stage: it gets the budget minus
# what the stages after the clock start spent, floored at 1 s, or the
# transport default when there is no task timeout.
describe "PluginManager task-timeout exec budget" do
  describe ".remaining_exec_timeout" do
    it "keeps the transport default when there is no task timeout" do
      Krikri::PluginManager.remaining_exec_timeout(nil, nil).must_equal(Krikri::SSHManager::DEFAULT_EXEC_TIMEOUT_SECONDS)
    end

    it "hands the exec the whole budget when the clock just started" do
      (Krikri::PluginManager.remaining_exec_timeout(Time.instant, 10_i64) >= 9).must_equal(true)
    end

    it "floors at 1s when earlier stages already ate the whole budget" do
      Krikri::PluginManager.remaining_exec_timeout(Time.instant - 5.seconds, 2_i64).must_equal(1)
    end
  end
end

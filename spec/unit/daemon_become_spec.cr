require "../spec_helper"
require "../../src/crystal_play/plugin_manager"
require "../../src/crystal_play/ssh_manager"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item 1 - `become:` under the
# persistent daemon.
#
# Before this, `PluginManager.daemon_eligible?` returned false for
# every `become: true` task, which is nearly every task in nearly every
# real Galaxy role: the project's single biggest measured optimization
# was switched off for the overwhelming majority of real work, and the
# published warm speedups were largely produced by the per-task
# fallback path instead.
#
# The escalation itself is deliberately identical to the one-shot
# path's - `sudo -n -u <become_user> --`, the same string
# #remote_plugin_target builds - so a host where one-shot become works
# has a working daemon, and a host where it doesn't fails the same way
# and falls back.
describe "daemon become eligibility" do
  it "no longer disqualifies a task just because it uses become:" do
    CrystalPlay::PluginManager.daemon_eligible?("command", true).should be_true
    CrystalPlay::PluginManager.daemon_eligible?("ansible.builtin.copy", true).should be_true
  end

  it "no longer disqualifies facts either (item 2)" do
    # `facts` was excluded while it was missing from the fat plugin
    # binary's dispatch table - a daemon request for it would only ever
    # have hit the "unknown plugin" fallback. Item 2 put it in the fat
    # binary, so the exclusion set is now empty.
    CrystalPlay::PluginManager.daemon_eligible?("facts", false).should be_true
    CrystalPlay::PluginManager::DAEMON_INELIGIBLE_PLUGINS.should be_empty
  end

  it "keeps the become_user allow-list that guards the daemon command line" do
    # become_user is interpolated straight into the daemon's own ssh
    # command line (`sudo -n -u <user> -- <binary> --daemon`), exactly
    # as it is into the one-shot target string, so the same allow-list
    # is the security boundary for both.
    CrystalPlay::PluginManager.valid_become_user?("deploy").should be_true
    CrystalPlay::PluginManager.valid_become_user?("root; rm -rf /").should be_false
    CrystalPlay::PluginManager.valid_become_user?("a b").should be_false
  end

  it "builds the same sudo wrapper for a become: target as the one-shot path" do
    CrystalPlay::PluginManager.remote_plugin_target("command", true, "deploy")
      .should eq("sudo -n -u deploy -- #{CrystalPlay::PluginManager::REMOTE_PLUGIN_DIR}/command")
    CrystalPlay::PluginManager.remote_plugin_target("command", false, nil)
      .should eq("#{CrystalPlay::PluginManager::REMOTE_PLUGIN_DIR}/command")
  end

  it "treats a host with no failures as available for every become_user" do
    CrystalPlay::SSHManager.daemon_unavailable?("192.0.2.10", "root", 22, nil).should be_false
    CrystalPlay::SSHManager.daemon_unavailable?("192.0.2.10", "root", 22, "deploy").should be_false
  end
end

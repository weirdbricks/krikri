require "../spec_helper"
require "../../src/krikri/plugin_manager"

describe Krikri::PluginManager do
  describe ".become_needed?" do
    it "is false when escalating to the user we already are" do
      # Real Ansible's own gate (_low_level_execute_command):
      # `C.BECOME_ALLOW_SAME_USER or (buser != ruser or not any((ruser,
      # buser)))`. Since become_user defaults to root and most
      # inventories connect as root, the common `become: true` task runs
      # with NO sudo at all under real Ansible - verified live, on a host
      # with no sudo installed at all.
      Krikri::PluginManager.become_needed?(true, "root", "root").should be_false
    end

    it "is true when the become_user genuinely differs" do
      Krikri::PluginManager.become_needed?(true, "appuser", "root").should be_true
      Krikri::PluginManager.become_needed?(true, "root", "deploy").should be_true
    end

    it "is false whenever become itself is off" do
      Krikri::PluginManager.become_needed?(false, "appuser", "root").should be_false
    end

    it "escalates when neither user is known" do
      # real Ansible's `not any((ruser, buser))` arm: with nothing to
      # compare, it escalates rather than assuming they match.
      Krikri::PluginManager.become_needed?(true, nil, nil).should be_true
      Krikri::PluginManager.become_needed?(true, "", "").should be_true
    end

    it "honours ANSIBLE_BECOME_ALLOW_SAME_USER" do
      ENV["ANSIBLE_BECOME_ALLOW_SAME_USER"] = "true"
      begin
        Krikri::PluginManager.become_needed?(true, "root", "root").should be_true
      ensure
        ENV.delete("ANSIBLE_BECOME_ALLOW_SAME_USER")
      end
    end
  end

  describe ".remote_plugin_target" do
    it "omits the sudo wrapper for a same-user become" do
      Krikri::PluginManager.remote_plugin_target("copy", true, "root", "root")
        .should eq("#{Krikri::PluginManager::REMOTE_PLUGIN_DIR}/copy")
    end

    it "keeps it for a genuine escalation" do
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root")
        .should eq("sudo -n -u appuser -- #{Krikri::PluginManager::REMOTE_PLUGIN_DIR}/copy")
    end
  end
end

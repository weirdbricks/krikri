require "../minitest_helper"
require "../../src/krikri/plugin_manager"

describe "Krikri::PluginManager (become_needed_test.cr)" do
  serial! # mutates process-global state (ENV / engine settings)

  describe ".become_needed?" do
    it "is false when escalating to the user we already are" do
      # Ansible's own gate (_low_level_execute_command):
      # `C.BECOME_ALLOW_SAME_USER or (buser != ruser or not any((ruser,
      # buser)))`. Since become_user defaults to root and most
      # inventories connect as root, the common `become: true` task runs
      # with NO sudo at all under Ansible - verified live, on a host
      # with no sudo installed at all.
      Krikri::PluginManager.become_needed?(true, "root", "root").must_equal(false)
    end

    it "is true when the become_user genuinely differs" do
      Krikri::PluginManager.become_needed?(true, "appuser", "root").must_equal(true)
      Krikri::PluginManager.become_needed?(true, "root", "deploy").must_equal(true)
    end

    it "is false whenever become itself is off" do
      Krikri::PluginManager.become_needed?(false, "appuser", "root").must_equal(false)
    end

    it "escalates when neither user is known" do
      # Ansible's `not any((ruser, buser))` arm: with nothing to
      # compare, it escalates rather than assuming they match.
      Krikri::PluginManager.become_needed?(true, nil, nil).must_equal(true)
      Krikri::PluginManager.become_needed?(true, "", "").must_equal(true)
    end

    it "honours ANSIBLE_BECOME_ALLOW_SAME_USER" do
      ENV["ANSIBLE_BECOME_ALLOW_SAME_USER"] = "true"
      begin
        Krikri::PluginManager.become_needed?(true, "root", "root").must_equal(true)
      ensure
        ENV.delete("ANSIBLE_BECOME_ALLOW_SAME_USER")
      end
    end
  end

  describe ".local_become_would_fail?" do
    it "is false unless the dispatch stays on the controller" do
      Krikri::PluginManager.local_become_would_fail?(false, true, "krikri-spec-other-user", nil, false).must_equal(false)
    end

    it "is false whenever become is off" do
      Krikri::PluginManager.local_become_would_fail?(true, false, nil, nil, false).must_equal(false)
    end

    it "is true for a local sudo dispatch with no password and a refusing sudo" do
      # Issue #498's live shape: sudo needs a password, none is
      # configured, so the escalation dies before the module - and its
      # own argument validation - can ever run.
      Krikri::PluginManager.local_become_would_fail?(true, true, "krikri-spec-other-user", nil, false).must_equal(true)
    end

    it "is false when a become password is configured (sudo -S gets its try)" do
      Krikri::PluginManager.local_become_would_fail?(true, true, "krikri-spec-other-user", "hunter2", false).must_equal(false)
    end

    it "is false when sudo escalates non-interactively (NOPASSWD)" do
      Krikri::PluginManager.local_become_would_fail?(true, true, "krikri-spec-other-user", nil, true).must_equal(false)
    end

    it "is false when the escalation is a same-user no-op" do
      # become_needed?'s own gate: escalating to the user we already are
      # wraps nothing in sudo, so the argspec check keeps running. The
      # probe result is irrelevant here, passed false to prove it.
      user = Krikri::PluginManager.local_username
      Krikri::PluginManager.local_become_would_fail?(true, true, user, nil, false).must_equal(false)
    end
  end

  describe ".remote_plugin_target" do
    it "omits the sudo wrapper for a same-user become" do
      Krikri::PluginManager.remote_plugin_target("copy", true, "root", "root")
        .must_equal("#{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "keeps it for a genuine escalation" do
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root")
        .must_equal("sudo -H -n -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "shell-quotes a hostile become_user as defense in depth" do
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "root; rm -rf /", "deploy")
      target.must_include("sudo -H -n -u 'root; rm -rf /' --")
    end
  end
end

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

    it "passes become_flags to sudo in place of its own defaults" do
      # Ansible's sudo become plugin joins the effective become_flags where
      # its built-in `-H -S -n` defaults would sit - the configured list
      # REPLACES them, it is not appended. Live-verified against
      # ansible-core 2.21.6 with a logging sudo shim: `become_flags: '-E'`
      # runs `sudo -E -u root ...` (issue #1486: SSH_AUTH_SOCK survives
      # that, so an agent-authenticated `git clone` as root works).
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil, "-E")
      target.must_equal("sudo -E -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "uses sudo --login when become_flags ask for a login shell" do
      # `--login` is handed to sudo verbatim, so the become user's login
      # profile is sourced before the command - that is where a
      # profile-built PATH (a venv bin dir) comes from (issue #716:
      # `shell: nautobot-server migrate` with `become_flags: --login`
      # resolved the command there, rc 127 "command not found" without
      # it). Ansible passes no -n alongside it, and neither does this.
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil, "--login")
      target.must_equal("sudo --login -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "accepts -i as the login-shell token too" do
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil, "-i")
      target.must_include("sudo -i -u appuser --")
    end

    it "passes every configured flag through, not just the ones we model" do
      # `--setenv`/other sudo options used to be dropped on the floor; the
      # whole list now reaches sudo, as it does under ansible-playbook.
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil, "-n --setenv FOO=bar")
      target.must_equal("sudo -n --setenv FOO=bar -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "keeps the password wrapper's shape without become_flags" do
      wrapper = Krikri::PluginManager.sudo_password_become_wrapper("/tmp/copy", "appuser", "s3cret")
      wrapper.must_include("sudo -H -n -u appuser -- /tmp/copy")
      wrapper.must_include("sudo -H -S -p '' -u appuser -- /tmp/copy")
      wrapper.must_include("sudo -n -u appuser -- true")
    end

    it "does not claim a stdin password slot when become_flags give sudo no -S" do
      # `-E` replaces the default `-H -S -p ''`, leaving sudo no way to
      # read a password off stdin - so the password line must not be
      # prefixed to the plugin's config payload (that would feed the
      # password to the module as config). Sudo refuses, as it does under
      # ansible-playbook with the same flags.
      wrapper = Krikri::PluginManager.sudo_password_become_wrapper("/tmp/copy", "appuser", "s3cret", "-E")
      wrapper.must_equal("sudo -E -u appuser -- /tmp/copy")
    end

    it "keeps a configured -S prompt silent for the password wrapper" do
      wrapper = Krikri::PluginManager.sudo_password_become_wrapper("/tmp/copy", "appuser", "s3cret", "-E -S")
      wrapper.must_include("sudo -E -S -p '' -u appuser -- /tmp/copy")
      wrapper.must_include("printf '%s\\n' 's3cret'")
    end
  end

  describe ".local_sudo_argv (become_flags)" do
    it "replaces the default -H/-n with the task's flags" do
      Krikri::PluginManager.local_sudo_argv("appuser", "/tmp/copy", false, "-E")
        .must_equal(["-E", "-u", "appuser", "--", "/tmp/copy"])
      Krikri::PluginManager.local_sudo_argv("appuser", "/tmp/copy", false, "--login")
        .must_equal(["--login", "-u", "appuser", "--", "/tmp/copy"])
    end

    it "adds the silent prompt when the configured flags read stdin" do
      Krikri::PluginManager.local_sudo_argv("appuser", "/tmp/copy", true, "-S -H")
        .must_equal(["-S", "-H", "-p", "", "-u", "appuser", "--", "/tmp/copy"])
    end

    it "keeps the historical -H argv without become_flags" do
      Krikri::PluginManager.local_sudo_argv("appuser", "/tmp/copy", false, nil)
        .must_equal(["-H", "-n", "-u", "appuser", "--", "/tmp/copy"])
    end
  end

  describe ".sudo_become_flags" do
    it "defaults the no-password form to -H -n" do
      Krikri::PluginManager.sudo_become_flags(nil, false).must_equal(["-H", "-n"])
    end

    it "defaults the password form to -H -S -p ''" do
      Krikri::PluginManager.sudo_become_flags(nil, true).must_equal(["-H", "-S", "-p", ""])
    end

    it "strips -n/--non-interactive from configured flags when a password is fed" do
      # Ansible strips them the same way once it has a become password: -n
      # would make sudo fail instead of read it.
      Krikri::PluginManager.sudo_become_flags("-H -S -n", true).must_equal(["-H", "-S", "-p", ""])
      Krikri::PluginManager.sudo_become_flags("--non-interactive -H -S", true).must_equal(["-H", "-S", "-p", ""])
      Krikri::PluginManager.sudo_become_flags("-HnS", true).must_equal(["-HS", "-p", ""])
      Krikri::PluginManager.sudo_become_flags("-H -n", false).must_equal(["-H", "-n"])
    end

    it "splits quoted flag values into single argv tokens" do
      Krikri::PluginManager.sudo_become_flags("-p 'say hi' -H", false).must_equal(["-p", "say hi", "-H"])
    end
  end

  describe ".become_flags_set?" do
    it "treats nil and blank as unset" do
      Krikri::PluginManager.become_flags_set?(nil).must_equal(false)
      Krikri::PluginManager.become_flags_set?("").must_equal(false)
      Krikri::PluginManager.become_flags_set?("   ").must_equal(false)
      Krikri::PluginManager.become_flags_set?("-E").must_equal(true)
    end
  end

  describe ".daemon_eligible? (become_flags)" do
    it "refuses the daemon for any configured become_flags" do
      # The daemon spawns once under fixed sudo flags and never sees the
      # task's become_flags, so it cannot honour -i (issue #716) or -E
      # (issue #1486) - both have to take the one-shot path whose sudo
      # wrapper carries the flags.
      Krikri::PluginManager.daemon_eligible?("copy", true, "--login").must_equal(false)
      Krikri::PluginManager.daemon_eligible?("copy", true, "-i").must_equal(false)
      Krikri::PluginManager.daemon_eligible?("copy", true, "-E").must_equal(false)
    end

    it "stays eligible without become_flags" do
      Krikri::PluginManager.daemon_eligible?("copy", true, nil).must_equal(true)
      Krikri::PluginManager.daemon_eligible?("copy", true, "").must_equal(true)
    end
  end
end

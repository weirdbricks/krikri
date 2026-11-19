require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/batch_script"

# -K/--ask-become-pass/--become-password-file (and an inventory
# ansible_become_password/ansible_become_pass) must change how sudo is
# invoked: `sudo -H -n` stays the no-password behaviour, and with a
# password set the target becomes the probe + `sudo -H -S -p ''`
# wrapper that feeds the password on stdin - while a NOOPASSWD sudo
# (the common -K-with-passwordless-sudo case) still resolves to plain
# `sudo -H -n` with the config payload untouched. Pure command
# construction: no sudo/ssh process is spawned here.
describe "become password command construction (become_password_test.cr)" do
  describe "PluginManager.remote_plugin_target with a become password" do
    it "builds the probe + sudo -S wrapper instead of sudo -n" do
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", "pw123")
      dir = Krikri::PluginManager.remote_plugin_dir(nil)

      # NOOPASSWD probe: sudo -n, stderr discarded, so a passwordless
      # sudo takes this branch and stdin flows through untouched.
      target.includes?("if sudo -n -u appuser -- true 2>/dev/null; ").must_equal(true)
      target.includes?("then sudo -H -n -u appuser -- #{dir}/copy; ").must_equal(true)
      # The password-required branch: sudo -S with an empty prompt, and
      # the password line prepended to the same stdin stream. The
      # feeder's stderr is silenced (EPIPE noise when the consumer exits
      # before reading stdin - see sudo_password_become_wrapper).
      target.includes?("printf '%s\\n' 'pw123' 2>/dev/null; cat 2>/dev/null; } | ").must_equal(true)
      target.includes?("sudo -H -S -p '' -u appuser -- #{dir}/copy; fi").must_equal(true)
      # It is still ONE command fragment the usual pipe can target.
      target.starts_with?("if ").must_equal(true)
      target.ends_with?("fi").must_equal(true)
    end

    it "uses sudo -H -n when no password is set" do
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root")
        .must_equal("sudo -H -n -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil)
        .must_equal("sudo -H -n -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "prefixes execution sudo invocations with -H like ansible's become" do
      # -H sets HOME to the become user's, so ~/.ansible/tmp - and
      # ansible's unusable-tempdir warning when that home cannot be
      # created (issue #536) - resolves the way it does under ansible.
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root")
      target.includes?("sudo -H -n -u").must_equal(true)
    end

    it "needs no sudo at all when escalating to the user we already are" do
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "root", "root", "pw123")
      target.must_equal("#{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
      target.includes?("sudo").must_equal(false)
    end

    it "ignores the password when the task itself has no become" do
      target = Krikri::PluginManager.remote_plugin_target("copy", false, nil, "root", "pw123")
      target.must_equal("#{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
      target.includes?("sudo").must_equal(false)
    end

    it "shell-quotes a hostile become_user in probe and both branches" do
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "root; rm -rf /", "deploy", "pw")
      target.includes?("sudo -n -u 'root; rm -rf /' -- true 2>/dev/null").must_equal(true)
      target.includes?("sudo -H -S -p '' -u 'root; rm -rf /' --").must_equal(true)
    end

    it "single-quotes a password containing quotes and metacharacters" do
      wrapper = Krikri::PluginManager.sudo_password_become_wrapper("/p/copy", "deploy", "it's $`\"\\ pw;")
      wrapper.includes?("printf '%s\\n' 'it'\\''s $`\"\\ pw;' 2>/dev/null").must_equal(true)
      # The password only ever sits inside the printf argument, after
      # the format - never as a bare word a shell could expand.
      wrapper.includes?("$`\"\\ pw; ; cat").must_equal(false)
    end
  end

  describe "PluginManager local (ansible_connection=local) sudo argv/stdin" do
    it "uses sudo -S -p '' plus a prefixed stdin only when interactive" do
      Krikri::PluginManager.local_sudo_argv("appuser", "/p/copy", true)
        .must_equal(["-H", "-S", "-p", "", "-u", "appuser", "--", "/p/copy"])
      Krikri::PluginManager.local_sudo_argv("appuser", "/p/copy", false)
        .must_equal(["-H", "-n", "-u", "appuser", "--", "/p/copy"])
    end

    it "never puts the password in the sudo argv" do
      argv = Krikri::PluginManager.local_sudo_argv("appuser", "/p/copy", true)
      argv.any? { |arg| arg.includes?("pw") }.must_equal(false)
    end

    it "prefixes the password line on stdin exactly when sudo will read it" do
      Krikri::PluginManager.local_plugin_stdin("{config}", "pw123", true)
        .must_equal("pw123\n{config}")
      # NOOPASSWD (not interactive): the plugin's config must arrive
      # byte-identical - a stray password line would not parse as JSON.
      Krikri::PluginManager.local_plugin_stdin("{config}", "pw123", false)
        .must_equal("{config}")
      Krikri::PluginManager.local_plugin_stdin("{config}", nil, true)
        .must_equal("{config}")
    end
  end

  describe "SSHManager daemon sudo command" do
    it "keeps sudo -n (clean framed stdin) when no password is needed" do
      Krikri::SSHManager.daemon_remote_command("/p/command", "deploy")
        .must_equal("sudo -H -n -u 'deploy' -- '/p/command' --daemon")
      Krikri::SSHManager.daemon_remote_command("/p/command", nil)
        .must_equal("'/p/command' --daemon")
    end

    it "switches to sudo -S -p '' for the probed password case" do
      # The password itself is deliberately NOT a parameter of this
      # builder: this string is argv on both the local ssh process and
      # the remote shell's `bash -c`. #spawn_daemon writes the password
      # line into the daemon's stdin pipe ahead of the frames instead.
      cmd = Krikri::SSHManager.daemon_remote_command("/p/command", "deploy", true)
      cmd.must_equal("sudo -H -S -p '' -u 'deploy' -- '/p/command' --daemon")
      cmd.includes?("deploy'").must_equal(true)
    end

    it "forwards the controller TERM into every daemon, as ansible's ssh -tt does" do
      # Ansible's `-tt` is gated on `sudoable` (true for every POSIX
      # module exec) plus the absence of pipelined stdin, NOT on become:
      # a plain `command:` task over ssh sees the controller's TERM too
      # (live-verified against ansible-core 2.21.6, issue #1564), so the
      # non-become daemon carries it as well (issue #606).
      Krikri::SSHManager.daemon_remote_command("/p/command", "deploy", false, "xterm-ghostty")
        .must_equal("TERM='xterm-ghostty' sudo -H -n -u 'deploy' -- '/p/command' --daemon")
      Krikri::SSHManager.daemon_remote_command("/p/command", nil, false, "xterm-ghostty")
        .must_equal("TERM='xterm-ghostty' '/p/command' --daemon")
      Krikri::SSHManager.daemon_remote_command("/p/command", "deploy", false, "")
        .must_equal("sudo -H -n -u 'deploy' -- '/p/command' --daemon")
    end
  end

  describe "BatchScript with a become-password target" do
    it "embeds the wrapper as a step's plugin_target with rc capture intact" do
      wrapper = Krikri::PluginManager.sudo_password_become_wrapper(
        "/var/tmp/.krikri-playbook/plugins/copy", "deploy", "pw123")
      step = Krikri::BatchScript::Step.new(wrapper, %({"params":{}}), false, "copy", "deploy")
      script = Krikri::BatchScript.build("becomepwtest1", [step], "root")

      script.includes?(wrapper).must_equal(true)
      script.includes?(%(echo $? > "$D/0.rc")).must_equal(true)
      # The wrapper stays the tail of the usual base64 payload pipe.
      script.includes?(" | base64 -d | if sudo -n -u deploy -- true").must_equal(true)
      step.become_user.must_equal("deploy")
    end
  end

  describe "PluginManager.become_shell_wrapper (plain commands, e.g. reboot's shutdown)" do
    it "wraps a command in the same sudo -H -n escalation a module gets" do
      # Ansible's reboot action runs its shutdown/boot-time/test commands
      # through _low_level_execute_command(..., sudoable=True), so they
      # escalate like a module does (issue #1305).
      wrapper = Krikri::PluginManager.become_shell_wrapper("systemctl reboot", true, "appuser", "deploy")
      wrapper[:command].must_equal("sudo -H -n -u appuser -- /bin/sh -c 'systemctl reboot'")
      wrapper[:via_stdin].must_equal(false)
    end

    it "leaves the command alone when the task has no become" do
      wrapper = Krikri::PluginManager.become_shell_wrapper("cat /proc/sys/kernel/random/boot_id", false, nil, "root")
      wrapper[:command].must_equal("cat /proc/sys/kernel/random/boot_id")
      wrapper[:via_stdin].must_equal(false)
    end

    it "needs no sudo when escalating to the user we already are" do
      Krikri::PluginManager.become_shell_wrapper("whoami", true, "root", "root")[:command]
        .must_equal("whoami")
    end

    it "feeds a become password on stdin through sudo -S and keeps it out of argv" do
      wrapper = Krikri::PluginManager.become_shell_wrapper("systemctl reboot", true, "appuser", "deploy", "pw123")
      wrapper[:via_stdin].must_equal(true)
      wrapper[:command].includes?("if sudo -n -u appuser -- true 2>/dev/null; ").must_equal(true)
      wrapper[:command].includes?("then sudo -H -n -u appuser -- /bin/sh -c 'systemctl reboot'; ").must_equal(true)
      wrapper[:command].includes?("printf '%s\\n' 'pw123' | sudo -H -S -p '' -u appuser -- /bin/sh -c 'systemctl reboot'; fi").must_equal(true)
    end

    it "shell-quotes a command carrying quotes and metacharacters" do
      Krikri::PluginManager.become_shell_wrapper(%(sh -c "echo hi; reboot"), true, "appuser", "deploy")[:command]
        .must_equal(%(sudo -H -n -u appuser -- /bin/sh -c 'sh -c "echo hi; reboot"'))
    end
  end
end

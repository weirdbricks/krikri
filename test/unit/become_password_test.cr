require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/batch_script"

# -K/--ask-become-pass/--become-password-file (and an inventory
# ansible_become_password/ansible_become_pass) must change how sudo is
# invoked: `sudo -n` stays the no-password behaviour, and with a
# password set the target becomes the probe + `sudo -S -p ''` wrapper
# that feeds the password on stdin - while a NOOPASSWD sudo (the common
# -K-with-passwordless-sudo case) still resolves to plain `sudo -n`
# with the config payload untouched. Pure command construction: no
# sudo/ssh process is spawned here.
describe "become password command construction (become_password_test.cr)" do
  describe "PluginManager.remote_plugin_target with a become password" do
    it "builds the probe + sudo -S wrapper instead of sudo -n" do
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", "pw123")
      dir = Krikri::PluginManager.remote_plugin_dir(nil)

      # NOOPASSWD probe: sudo -n, stderr discarded, so a passwordless
      # sudo takes this branch and stdin flows through untouched.
      target.includes?("if sudo -n -u appuser -- true 2>/dev/null; ").must_equal(true)
      target.includes?("then sudo -n -u appuser -- #{dir}/copy; ").must_equal(true)
      # The password-required branch: sudo -S with an empty prompt, and
      # the password line prepended to the same stdin stream.
      target.includes?("printf '%s\\n' 'pw123'; cat; } | ").must_equal(true)
      target.includes?("sudo -S -p '' -u appuser -- #{dir}/copy; fi").must_equal(true)
      # It is still ONE command fragment the usual pipe can target.
      target.starts_with?("if ").must_equal(true)
      target.ends_with?("fi").must_equal(true)
    end

    it "keeps the historical sudo -n string when no password is set" do
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root")
        .must_equal("sudo -n -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil)
        .must_equal("sudo -n -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
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
      target.includes?("sudo -S -p '' -u 'root; rm -rf /' --").must_equal(true)
    end

    it "single-quotes a password containing quotes and metacharacters" do
      wrapper = Krikri::PluginManager.sudo_password_become_wrapper("/p/copy", "deploy", "it's $`\"\\ pw;")
      wrapper.includes?("printf '%s\\n' 'it'\\''s $`\"\\ pw;'").must_equal(true)
      # The password only ever sits inside the printf argument, after
      # the format - never as a bare word a shell could expand.
      wrapper.includes?("$`\"\\ pw; ; cat").must_equal(false)
    end
  end

  describe "PluginManager local (ansible_connection=local) sudo argv/stdin" do
    it "uses sudo -S -p '' plus a prefixed stdin only when interactive" do
      Krikri::PluginManager.local_sudo_argv("appuser", "/p/copy", true)
        .must_equal(["-S", "-p", "", "-u", "appuser", "--", "/p/copy"])
      Krikri::PluginManager.local_sudo_argv("appuser", "/p/copy", false)
        .must_equal(["-n", "-u", "appuser", "--", "/p/copy"])
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
        .must_equal("sudo -n -u 'deploy' -- '/p/command' --daemon")
      Krikri::SSHManager.daemon_remote_command("/p/command", nil)
        .must_equal("'/p/command' --daemon")
    end

    it "switches to sudo -S -p '' for the probed password case" do
      # The password itself is deliberately NOT a parameter of this
      # builder: this string is argv on both the local ssh process and
      # the remote shell's `bash -c`. #spawn_daemon writes the password
      # line into the daemon's stdin pipe ahead of the frames instead.
      cmd = Krikri::SSHManager.daemon_remote_command("/p/command", "deploy", true)
      cmd.must_equal("sudo -S -p '' -u 'deploy' -- '/p/command' --daemon")
      cmd.includes?("deploy'").must_equal(true)
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
end

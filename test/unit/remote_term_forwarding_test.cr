require "../minitest_helper"
require "../../src/krikri/plugin_manager"

# Real ansible wraps every module exec in `ssh -tt` (ssh's use_tty
# default) unless the module payload rides exec_command's in_data (i.e.
# pipelining is on), so the remote module process inherits the
# CONTROLLER's TERM through that pty. krikri's plugin dispatch has no
# pty, so the value has to ride along as an assignment prefix - without
# it a script that gates its color output on TERM (docksal's `fin`,
# issue #1564) renders plain text where ansible's output carries ESC
# codes.
describe "Krikri::PluginManager (remote_term_forwarding_test.cr)" do
  serial! # mutates process-global ENV

  # Runs the block with TERM/*pipelining_env* pinned, restoring whatever
  # the suite had afterwards - the option's two layers are process-wide.
  private def with_term_env(term : String?, pipelining : String? = nil, &)
    saved_term = ENV["TERM"]?
    saved_pipelining = ENV["ANSIBLE_PIPELINING"]?
    begin
      if term
        ENV["TERM"] = term
      else
        ENV.delete("TERM")
      end
      if pipelining
        ENV["ANSIBLE_PIPELINING"] = pipelining
      else
        ENV.delete("ANSIBLE_PIPELINING")
      end
      yield
    ensure
      if saved_term
        ENV["TERM"] = saved_term
      else
        ENV.delete("TERM")
      end
      if saved_pipelining
        ENV["ANSIBLE_PIPELINING"] = saved_pipelining
      else
        ENV.delete("ANSIBLE_PIPELINING")
      end
    end
  end

  describe ".remote_term_forwarding" do
    it "forwards the controller's TERM when pipelining is off" do
      with_term_env("xterm-256color") do
        Krikri::PluginManager.remote_term_forwarding
          .must_equal("xterm-256color")
      end
    end

    it "forwards nothing under the ansible_pipelining vars" do
      # Pipelining makes the module exec carry stdin, so ansible drops
      # -tt and allocates no tty: the target's own TERM stands, which is
      # what krikri already produced (live-verified against
      # ansible-core 2.21.6: TERM=[dumb] with pipelining, the
      # controller's value without).
      with_term_env("xterm-256color") do
        Krikri::PluginManager.remote_term_forwarding({"ansible_pipelining" => JSON::Any.new(true)}).must_be_nil
        Krikri::PluginManager.remote_term_forwarding({"ansible_ssh_pipelining" => JSON::Any.new("yes")}).must_be_nil
      end
    end

    it "forwards nothing under the ANSIBLE_PIPELINING env layer" do
      with_term_env("xterm-256color", pipelining: "True") do
        Krikri::PluginManager.remote_term_forwarding.must_be_nil
      end
    end

    it "forwards nothing when the controller has no TERM" do
      with_term_env(nil) do
        Krikri::PluginManager.remote_term_forwarding.must_be_nil
      end
      with_term_env("") do
        Krikri::PluginManager.remote_term_forwarding.must_be_nil
      end
    end
  end

  describe ".remote_plugin_target with a forwarded TERM" do
    it "prefixes the bare plugin path when no escalation is needed" do
      # become: true to the user we already are - the shape the docksal
      # round ran, where the target's sshd exported TERM=dumb and fin
      # printed its notice as plain text.
      Krikri::PluginManager.remote_plugin_target("copy", true, "root", "root", nil, nil, "xterm-256color")
        .must_equal("TERM=xterm-256color #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "prefixes the sudo invocation, not the plugin path" do
      # sudo is what installs the value into the become user's
      # environment (the become daemon's own `TERM=... sudo` spawn has
      # relied on that since issue #606).
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", nil, nil, "xterm-256color")
        .must_equal("TERM=xterm-256color sudo -H -n -u appuser -- #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "prefixes both sudo branches of the become-password wrapper" do
      # The wrapper is `if <probe>; then <sudo>; else ... | <sudo>; fi`,
      # so an assignment in front of the `if` would be a shell syntax
      # error - each launching sudo takes its own.
      target = Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", "pw123", nil, "xterm-256color")
      dir = Krikri::PluginManager.remote_plugin_dir(nil)
      target.includes?("then TERM=xterm-256color sudo -H -n -u appuser -- #{dir}/copy; ").must_equal(true)
      target.includes?("| TERM=xterm-256color sudo -H -S -p '' -u appuser -- #{dir}/copy; fi").must_equal(true)
      # The NOOPASSWD probe itself sets nothing up: it only decides
      # which branch feeds stdin.
      target.starts_with?("if sudo -n -u appuser -- true 2>/dev/null; ").must_equal(true)
    end

    it "quotes a TERM holding shell metacharacters" do
      Krikri::PluginManager.remote_plugin_target("copy", false, nil, "root", nil, nil, "x; rm -rf /")
        .must_equal("TERM='x; rm -rf /' #{Krikri::PluginManager.remote_plugin_dir(nil)}/copy")
    end

    it "leaves every launch shape untouched without a TERM to forward" do
      dir = Krikri::PluginManager.remote_plugin_dir(nil)
      Krikri::PluginManager.remote_plugin_target("copy", true, "root", "root")
        .must_equal("#{dir}/copy")
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root")
        .must_equal("sudo -H -n -u appuser -- #{dir}/copy")
      Krikri::PluginManager.remote_plugin_target("copy", true, "appuser", "root", "pw123")
        .starts_with?("if sudo -n -u appuser -- true 2>/dev/null; then sudo -H -n").must_equal(true)
    end
  end
end

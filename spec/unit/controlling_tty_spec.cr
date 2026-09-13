require "../spec_helper"

# Real ansible-core's ssh connection plugin asks for a remote pty
# (`ssh -tt`) for ordinary module dispatch, so anything a `command:`/
# `shell:` task spawns on the target can open `/dev/tty`. This engine
# never passes -t/-tt (a pty would merge stderr into stdout and mangle
# line endings on the very channel that carries each plugin's JSON
# result), so `ControllingTty` manufactures one inside the plugin
# process instead - see src/krikri/plugin_helpers/controlling_tty.cr.
#
# Driven through the real `command` plugin binary rather than the module
# directly, because the behavior under test is exactly "a child spawned
# by the plugin process inherits a controlling terminal", and because
# the plugin has to be spawned as somebody's child for setsid() to be
# allowed at all (a process that is already a process-group leader
# cannot start a new session - the same reason this works under ssh,
# where the plugin is a child of the remote shell).
#
# NOTE: the *transport* half of this - that requesting no pty from ssh
# still leaves every plugin's JSON result uncorrupted over the one-shot,
# batched and persistent-daemon paths - has no spec and is verified live
# against a real host instead (see KNOWN_MISSING.md's round narrative),
# the same convention this repo already uses for real dpkg/apt/crontab
# mutation.
describe "controlling terminal for command:/shell: subprocesses" do
  it "lets a command: subprocess open /dev/tty without polluting stdout/stderr" do
    result = PluginSpecHelper.run("command", {
      "argv" => %(["/bin/sh", "-c", "echo tty-banner > /dev/tty; echo out1; echo err1 >&2"]),
    })

    result["rc"].as_i.should eq(0)
    result["failed"]?.try(&.as_bool).should be_falsey
    # The banner went to the terminal, which nothing on the controller
    # reads - it must not appear in either captured stream, and the two
    # streams must stay separate (a pty would have merged them).
    result["stdout"].as_s.should eq("out1")
    result["stderr"].as_s.should eq("err1")
  end

  it "keeps ordinary multi-line command: output byte-exact (no CRLF translation)" do
    result = PluginSpecHelper.run("command", {
      "argv" => %(["/bin/sh", "-c", "printf 'l1\\nl2\\nl3\\n'; printf 'e1\\ne2\\n' >&2"]),
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("l1\nl2\nl3")
    result["stderr"].as_s.should eq("e1\ne2")
  end

  it "lets a shell: command open /dev/tty and still returns clean stdout" do
    result = PluginSpecHelper.run("shell", {
      "cmd" => "echo tty-banner > /dev/tty; echo shell-ok",
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("shell-ok")
  end
end

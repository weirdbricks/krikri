require "../minitest_helper"

# ansible-core's ssh connection plugin asks for a remote pty
# (`ssh -tt`) for ordinary module dispatch, so anything a `command:`/
# `shell:` task spawns on the target can open `/dev/tty`. This engine
# never passes -t/-tt (a pty would merge stderr into stdout and mangle
# line endings on the very channel that carries each plugin's JSON
# result), so `ControllingTty` manufactures one inside the plugin
# process instead - see src/krikri/plugin_helpers/controlling_tty.cr.
# The executor marks a remote dispatch with `__krikri_remote_tty`; a
# local one keeps only the terminal the engine itself inherited.
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
  # A process's controlling tty, as `ps` names it ("?" when the process
  # has none) - the property a child only has when something put it in a
  # session with a terminal.
  def controlling_tty_name(pid : Int64) : String
    output = IO::Memory.new
    Process.run("ps", ["-o", "tty=", "-p", pid.to_s], output: output)
    output.to_s.strip
  end

  it "lets a command: subprocess open /dev/tty without polluting stdout/stderr" do
    result = PluginSpecHelper.run("command", {
      "__krikri_remote_tty" => "1",
      "argv"                => %(["/bin/sh", "-c", "echo tty-banner > /dev/tty; echo out1; echo err1 >&2"]),
    })

    result["rc"].as_i.must_equal(0)
    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
    # The banner went to the terminal, which nothing on the controller
    # reads - it must not appear in either captured stream, and the two
    # streams must stay separate (a pty would have merged them).
    result["stdout"].as_s.must_equal("out1")
    result["stderr"].as_s.must_equal("err1")
  end

  it "keeps ordinary multi-line command: output byte-exact (no CRLF translation)" do
    result = PluginSpecHelper.run("command", {
      "argv" => %(["/bin/sh", "-c", "printf 'l1\\nl2\\nl3\\n'; printf 'e1\\ne2\\n' >&2"]),
    })

    result["rc"].as_i.must_equal(0)
    result["stdout"].as_s.must_equal("l1\nl2\nl3")
    result["stderr"].as_s.must_equal("e1\ne2")
  end

  it "lets a shell: command open /dev/tty and still returns clean stdout" do
    result = PluginSpecHelper.run("shell", {
      "__krikri_remote_tty" => "1",
      "cmd"                 => "echo tty-banner > /dev/tty; echo shell-ok",
    })

    result["rc"].as_i.must_equal(0)
    result["stdout"].as_s.must_equal("shell-ok")
  end

  # Issue #1728: real's LOCAL connection never asks ssh for a pty, so a
  # local module's children see exactly the terminal ansible-playbook
  # itself inherited - usually none. A manufactured tty there made
  # `sudo`'s password prompt block forever on /dev/tty where real answers
  # "sudo: a terminal is required" at once.
  it "leaves a local-connection command with only the terminal this process has" do
    own_tty = controlling_tty_name(Process.pid)
    result = PluginSpecHelper.run("command", {
      "argv" => %(["/bin/sh", "-c", "ps -o tty= -p $$"]),
    })

    result["rc"].as_i.must_equal(0)
    result["stdout"].as_s.strip.must_equal(own_tty)
  end
end

require "../minitest_helper"
require "../../src/krikri/local_executor"

describe Krikri::LocalExecutor do
  describe ".exec" do
    it "captures stdout and the exit code for a normal command" do
      result = Krikri::LocalExecutor.exec("echo hello world")
      result[:exit_code].must_equal(0)
      result[:stdout].must_equal("hello world\n")
      result[:stderr].must_equal("")
    end

    it "captures stderr and a nonzero exit code" do
      result = Krikri::LocalExecutor.exec("echo oops >&2; exit 3")
      result[:exit_code].must_equal(3)
      result[:stderr].must_equal("oops\n")
    end

    it "captures large output in full, without truncation" do
      result = Krikri::LocalExecutor.exec("yes x | head -c 500000")
      result[:exit_code].must_equal(0)
      result[:stdout].bytesize.must_equal(500000)
    end

    # Regression test for passing argv directly (Process.new("/bin/bash",
    # ["-c", command]), no shell: true) instead of a hand-escaped
    # "/bin/bash -c '...'" string: the command now travels as a single
    # argv element, so it must survive embedded single quotes,
    # backslashes, and "$" untouched, with no shell re-parsing it.
    it "handles embedded single quotes, backslashes, and $ correctly" do
      result = Krikri::LocalExecutor.exec(%(echo 'it'"'"'s a $HOME\\test'))
      result[:exit_code].must_equal(0)
      result[:stdout].must_equal("it's a $HOME\\test\n")
    end

    # Regression test for a real bug shipped in the same round as the
    # "skip bash -c when no shell metacharacters" optimization above: a
    # leading `NAME=value` env-assignment prefix (apt.cr/package.cr's own
    # `DEBIAN_FRONTEND=noninteractive apt-get install ...`, no `export`/
    # `;` involved) has no shell metacharacters at all, so the fast path
    # argv-split it with "DEBIAN_FRONTEND=noninteractive" as argv[0] -
    # ENOENT, since that's shell env-assignment syntax, not a real
    # executable name.
    it "still routes a leading NAME=value env-assignment prefix through the shell" do
      result = Krikri::LocalExecutor.exec("SOME_VAR=hello sh -c 'echo $SOME_VAR'")
      result[:exit_code].must_equal(0)
      result[:stdout].must_equal("hello\n")
    end

    # A later argument containing "=" (a normal --opt=value flag) is not
    # env-assignment syntax and must not force the shell path.
    it "does not mistake a later --opt=value argument for a leading env assignment" do
      result = Krikri::LocalExecutor.exec("echo --opt=value")
      result[:exit_code].must_equal(0)
      result[:stdout].must_equal("--opt=value\n")
    end

    # Security regression for the old `export K='V'; <cmd>` environment:
    # prefix: the prefix lived INSIDE the bash -c string, i.e. in the
    # shell process's argv, where any local user's `ps` could read secret
    # values while the task ran. The task environment now travels through
    # the child process's own environment (Process.new's env:, exactly how
    # Ansible hands the dict to subprocess), so the child still sees
    # the byte-exact value...
    it "applies env through the child environment, byte-exact, including shell metacharacters" do
      secret = "s3cr3t'x\"y\$z`w -dash\nline2"
      result = Krikri::LocalExecutor.exec(
        "printf '%s' \"$KRIKRI_TEST_SECRET\"",
        force_shell: true,
        env: {"KRIKRI_TEST_SECRET" => secret}
      )
      result[:exit_code].must_equal(0)
      result[:stdout].must_equal(secret)
    end

    # ...while the shell process's argv (read back via the shell's own
    # /proc/<pid>/cmdline) carries only the command - never the value.
    it "keeps an env value out of the spawned shell's argv" do
      result = Krikri::LocalExecutor.exec(
        "tr '\\0' ' ' < /proc/$$/cmdline",
        force_shell: true,
        env: {"KRIKRI_TEST_SECRET" => "sekrit-ps-value"}
      )
      result[:exit_code].must_equal(0)
      result[:stdout].includes?("sekrit-ps-value").must_equal(false)
      # Sanity: the shell really was a `bash -c` (its argv is visible above)
      result[:stdout].includes?("bash").must_equal(true)
    end

    # Ansible overlays the task environment ONTO the module process's
    # inherited environment (the old export prefix inherited it too), so an
    # override must not wipe the rest of the environment.
    it "merges env over the inherited environment instead of replacing it" do
      result = Krikri::LocalExecutor.exec(
        "echo \"HOME=$HOME KRIKRI_TEST_SECRET=$KRIKRI_TEST_SECRET\"",
        force_shell: true,
        env: {"KRIKRI_TEST_SECRET" => "v"}
      )
      result[:stdout].includes?("KRIKRI_TEST_SECRET=v").must_equal(true)
      result[:stdout].matches?(/HOME=\S/).must_equal(true)
    end

    # With an `environment: PATH: ...` override the executable lookup must
    # use the OVERRIDDEN PATH (the shell the child became resolves with its
    # own env), not the parent's - which is why an env-bearing command is
    # always routed through the shell path even when it has no
    # metacharacters.
    it "resolves the executable against an env PATH override" do
      result = Krikri::LocalExecutor.exec(
        "true",
        env: {"PATH" => "/usr/bin:/bin"}
      )
      result[:exit_code].must_equal(0)
    end

    # Regression test for a stdout-truncation flake seen in CI: used to
    # spawn with Process::Redirect::Pipe and call Process#wait right after
    # starting the drain fibers, but wait's own `ensure` closes the
    # process's pipes the moment it returns - which can beat a drain fiber
    # that hasn't yet read output the child left buffered in the pipe
    # (under a loaded, parallel test runner the drain fiber may not even
    # have been scheduled yet). The drain then died on "Closed stream",
    # its bare `rescue` swallowed the error, and the capture came back
    # empty. Each iteration here is a command that prints and exits
    # immediately - the shape that lost the race.
    it "captures stdout in full across many immediately-exiting commands" do
      100.times do |i|
        result = Krikri::LocalExecutor.exec("SOME_VAR=hello#{i} sh -c 'echo $SOME_VAR'")
        result[:exit_code].must_equal(0)
        result[:stdout].must_equal("hello#{i}\n")
        result[:stderr].must_equal("")
      end
    end

    # Regression test for a real, previously-shipped bug: `sleep N && daemon &`
    # backgrounds a *shell* that blocks in its own wait() on `daemon` (nohup
    # only suppresses SIGHUP, it doesn't exempt a child from its parent's own
    # wait()) - if `daemon` never exits, neither does that shell, and the
    # stdout/stderr pipe it's still holding open never reaches EOF. Passing
    # output/error as a plain IO makes Process#wait block until EOF, so this
    # used to hang LocalExecutor.exec forever even though the process it
    # actually spawned (the outer bash -c) had long since exited.
    it "does not hang when a backgrounded command chains a never-exiting daemon after &&" do
      marker = File.tempname("local-executor-spec-daemon-marker")

      started = Time.instant
      result = Krikri::LocalExecutor.exec("sleep 0.1 && (touch #{marker}; tail -f /dev/null) &")
      elapsed = Time.instant - started

      result[:exit_code].must_equal(0)
      expect((elapsed.total_seconds) < (3.0)).must_equal(true)

      # The backgrounded daemon should still actually be running - this
      # isn't testing that the command failed to start, only that waiting
      # for its own output doesn't block the caller.
      # Polled for up to 5s: on a loaded machine (parallel test runs) the
      # backgrounded subshell can take well over half a second to get
      # scheduled, and a pass still returns as soon as the marker appears.
      100.times do
        break if File.exists?(marker)
        sleep 50.milliseconds
      end
      File.exists?(marker).must_equal(true)
    ensure
      `pkill -f "tail -f /dev/null" 2>/dev/null`
      File.delete(marker) if marker && File.exists?(marker)
    end
  end
end

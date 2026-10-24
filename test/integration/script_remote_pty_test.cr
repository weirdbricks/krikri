require "../minitest_helper"

# The remote script run's result shaping (issue #298): on a real remote
# host ansible's script action runs the staged file through a `ssh -tt`
# pty session - the pty MERGES the script's stderr into its stdout in
# execution order (every \n arrives \r\n) while the ssh client leaves
# only its own "Shared connection to <addr> closed." notice on stderr.
# The plugin can't open a mux session without a host, but the marker
# (__script_ssh_addr, set by TaskExecutor#stage_script_src for every
# remote-staged script) switches the same shaping on here against a run
# executed locally - which is exactly how the plugin behaves when it
# really runs on the target (it's uploaded there and the marker is the
# only remote-vs-remote thing it can see). The __script_tmp_dir rm -rf
# cleanup rides the same marker contract.
describe "script plugin remote-pty simulation (issue #298)" do
  it "merges the two streams in execution order, CRLF-encodes stdout, reports the ssh-close notice as stderr" do
    script = PluginSpecHelper.tmp_path("pty_merge.sh")
    File.write(script, "#!/bin/bash\necho out-one\necho err-one >&2\necho out-two\nprintf 'no-newline-tail'\n")
    File.chmod(script, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => script, "__script_ssh_addr" => "203.0.113.9"})

    # The merged capture in execution order (out-then-err-then-out), ONLCR
    # \r\n after every \n, and the un-terminated final line stays raw.
    result["stdout"].as_s.must_equal("out-one\r\nerr-one\r\nout-two\r\nno-newline-tail")
    result["stderr"].as_s.must_equal("Shared connection to 203.0.113.9 closed.\r\n")
    result["stdout_lines"].as_a.map(&.as_s).must_equal(["out-one", "err-one", "out-two", "no-newline-tail"])
    result["stderr_lines"].as_a.map(&.as_s).must_equal(["Shared connection to 203.0.113.9 closed."])
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["rc"].as_i.must_equal(0)
  ensure
    File.delete(script) if script && File.exists?(script)
  end

  it "keeps rc/failed/msg on a failing merged run and still ends stdout with \r\n" do
    script = PluginSpecHelper.tmp_path("pty_fail.sh")
    File.write(script, "#!/bin/bash\necho bad-err >&2\necho bad-out\nexit 7\n")
    File.chmod(script, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => script, "__script_ssh_addr" => "192.0.2.77"})

    result["stdout"].as_s.must_equal("bad-err\r\nbad-out\r\n")
    result["stderr"].as_s.must_equal("Shared connection to 192.0.2.77 closed.\r\n")
    result["stdout_lines"].as_a.map(&.as_s).must_equal(["bad-err", "bad-out"])
    result["stderr_lines"].as_a.map(&.as_s).must_equal(["Shared connection to 192.0.2.77 closed."])
    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i.must_equal(7)
    result["msg"].as_s.must_equal("non-zero return code")
  ensure
    File.delete(script) if script && File.exists?(script)
  end

  it "removes the whole per-task staging dir via __script_tmp_dir" do
    dir = PluginSpecHelper.tmp_path("ansible-tmp-1792822794.6691642-3684055-8664083885542")
    FileUtils.mkdir_p(dir, 0o700)
    script = File.join(dir, "pypy_install_pip.sh")
    File.write(script, "#!/bin/bash\necho staged-and-removed\n")
    File.chmod(script, 0o755)

    result = PluginSpecHelper.run("script", {
      "cmd"                    => script,
      "__script_ssh_addr"      => "203.0.113.9",
      "__cleanup_after_script" => "true",
      "__script_tmp_dir"       => dir,
    })

    result["stdout"].as_s.must_equal("staged-and-removed\r\n")
    # ansible's script.py removes the whole per-task tmp dir in its
    # finally clause, not just the staged file.
    File.exists?(dir).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir && File.exists?(dir)
  end

  it "does not reshape or clean anything without the remote markers (local run)" do
    script = PluginSpecHelper.tmp_path("pty_absent.sh")
    File.write(script, "#!/bin/bash\necho out-one\necho err-one >&2\n")
    File.chmod(script, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => script})

    # No pty on a local connection: the streams stay separate, the
    # trailing \n stays (real's local capture strips nothing), and the
    # untouched controller-side script survives a markerless run's
    # cleanup no-op (a local run never staged anything to clean).
    result["stdout"].as_s.must_equal("out-one\n")
    result["stderr"].as_s.must_equal("err-one\n")
    result["stdout_lines"].as_a.map(&.as_s).must_equal(["out-one"])
    File.exists?(script).must_equal(true)
  end
end

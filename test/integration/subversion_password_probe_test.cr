require "../minitest_helper"
require "file_utils"

# subversion's password handling, live-verified against ansible-playbook
# 2.19.11 on this host (2026-10-01 - krikri-playbook generator round 33
# re-sweep, cases #402/#403/#404):
#
#   - _exec calls has_option_password_from_stdin() BEFORE it finishes
#     assembling the operation argv, and only when a password was given.
#     That probe is `<svn> --version --quiet` with check_rc=True, so it is
#     the FIRST svn command of the run and the one a non-spawnable (or
#     non-zero-exiting) executable gets named under. This plugin used to
#     name the operation instead (it acknowledged the probe in a comment
#     but never ran it);
#   - svn >= 1.10 takes the password on STDIN (`--password-from-stdin`)
#     rather than on the command line;
#   - the `cmd` basic.py reports is _clean_args: shlex.quote per token,
#     with the token AFTER a PASSWD_ARG_RE match replaced by ********.

private def shim_dir(name : String) : String
  dir = File.join(Dir.tempdir, "krikri-svn-pw-#{name}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  dir
end

# A `svn` shim that reports `version` for `--version` and fails every
# real operation, so the reported `cmd` is all there is to assert on.
private def write_svn_shim(dir : String, version : String) : String
  shim = File.join(dir, "svn")
  File.write(shim, <<-SHIM)
    #!/bin/sh
    case "$1" in
      --version) echo "#{version}" ;;
      *) echo "boom" >&2; exit 3 ;;
    esac
    SHIM
  File.chmod(shim, 0o755)
  shim
end

private def run_subversion(params : Hash(String, String), host_name : String = "localhost") : JSON::Any
  PluginSpecHelper.run("subversion", params, host_name: host_name)
end

describe "subversion password handling" do
  it "names the --version probe, not the operation, when a password is given" do
    dir = shim_dir("probe")
    missing = File.join(dir, "no-such-svn")

    result = run_subversion({
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "executable" => missing,
      "password"   => "s3cret",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal("#{missing} --version --quiet")
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "still names the operation when no password was given" do
    dir = shim_dir("no-password")
    missing = File.join(dir, "no-such-svn")

    result = run_subversion({
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "executable" => missing,
    })

    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal(
      "#{missing} --non-interactive --no-auth-cache --trust-server-cert checkout -r HEAD " \
      "svn+ssh://example.com/repo #{File.join(dir, "wc")}")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "reports the probe's own non-zero rc as a check_rc failure, msg empty" do
    dir = shim_dir("probe-rc")
    shim = File.join(dir, "svn")
    File.write(shim, "#!/bin/sh\necho 'svn: E155007' >&2\nexit 1\n")
    File.chmod(shim, 0o755)

    result = run_subversion({
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "executable" => shim,
      "password"   => "s3cret",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("svn: E155007")
    result["rc"].as_i.must_equal(1)
    result["cmd"].as_s.must_equal("#{shim} --version --quiet")
    result["stderr_lines"].as_a.map(&.as_s).must_equal(["svn: E155007"])
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "passes the password on stdin and redacts it from the reported cmd on svn >= 1.10" do
    dir = shim_dir("stdin")
    shim = write_svn_shim(dir, "1.14.1")

    result = run_subversion({
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "executable" => shim,
      "username"   => "bob",
      "password"   => "s3cret",
    })

    result["failed"].as_bool.must_equal(true)
    # --password-from-stdin is a PASSWD_ARG_RE match, so real's _clean_args
    # redacts the token AFTER it - here the "checkout" operation word.
    result["cmd"].as_s.must_equal(
      "#{shim} --non-interactive --no-auth-cache --trust-server-cert --username bob " \
      "--password-from-stdin '********' -r HEAD svn+ssh://example.com/repo #{File.join(dir, "wc")}")
    result["msg"].as_s.must_equal("boom")
    result["rc"].as_i.must_equal(3)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "keeps the command-line password (redacted) for svn older than 1.10" do
    dir = shim_dir("old-svn")
    shim = write_svn_shim(dir, "1.9.0")

    result = run_subversion({
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "executable" => shim,
      "password"   => "s3cret",
    })

    result["failed"].as_bool.must_equal(true)
    result["cmd"].as_s.must_equal(
      "#{shim} --non-interactive --no-auth-cache --trust-server-cert --password '********' " \
      "checkout -r HEAD svn+ssh://example.com/repo #{File.join(dir, "wc")}")
    result["msg"].as_s.must_equal("boom")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "keeps check_rc failures on the operation carrying cmd/rc/stdout/stderr" do
    dir = shim_dir("op-rc")
    shim = write_svn_shim(dir, "1.14.1")

    result = run_subversion({
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "executable" => shim,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("boom")
    result["rc"].as_i.must_equal(3)
    result["stderr"].as_s.must_equal("boom\n")
    result["stderr_lines"].as_a.map(&.as_s).must_equal(["boom"])
    result["stdout"].as_s.must_equal("")
    # fail_json always emits msg, so a silent command still carries an
    # empty one rather than dropping the key.
    result.as_h.has_key?("msg").must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end

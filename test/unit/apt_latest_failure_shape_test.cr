require "../minitest_helper"
require "file_utils"

# Issue #439 (buluma.handbrake): `apt: state=latest` whose apt-get run
# fails (the role's handbrake pin hit "E: Unable to correct problems, you
# have held broken packages") diverged from real ansible in two ways,
# both live-verified against ansible-playbook 2.19.11:
#   1. the "'cmd' failed" msg quoted a FIVE-space run before "install"
#      where real install()'s eight-slot format string keeps the empty
#      fixed/check_arg slots' separators (seven spaces);
#   2. the failure result carried only msg (+ the backfilled
#      cache_updated), where real's install() failure data is
#      dict(msg=..., stdout=out, stderr=err, rc=rc) with main() appending
#      the cache keys and _return_formatted adding stdout_lines/
#      stderr_lines - the state=present path already mirrored that shape,
#      this path didn't.
#
# The plugin wiring is tested through the real plugin binary with fake
# `apt-cache`/`dpkg-query`/`apt-get` shims on PATH, injected via the
# `_environment` param (same pattern as apt_virtual_pin_test.cr). The
# apt-get shim always fails rc=100 while logging its argv - the seven-space
# shape is observable in that log without any real package operation.

private def with_apt_latest_failure_shims(&)
  dir = PluginSpecHelper.tmp_path("fake-apt-latest-failure")
  log = PluginSpecHelper.tmp_path("apt-get-latest-failure-invocations")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  File.write(File.join(dir, "apt-cache"), <<-'SH')
    #!/bin/sh
    printf 'bash:\n  Installed: (none)\n  Candidate: 5.2-1\n  Version table:\n     5.2-1 500\n        500 http://archive.ubuntu.com/ubuntu jammy/main amd64 Packages\n'
    SH
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\nexit 1\n")
  File.write(File.join(dir, "apt-get"), <<-SH)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    echo "E: Unable to correct problems, you have held broken packages." >&2
    exit 100
    SH
  ["apt-cache", "dpkg-query", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {
    "PATH"             => "#{dir}:/usr/bin:/bin",
    "KRIKRI_APT_CALLS" => log,
  }.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "apt state=latest install failure shape (issue 439)" do
  it "quotes real's eight-slot command shape and carries the full failure data" do
    with_apt_latest_failure_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "bash",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      # Seven spaces between the lock-timeout option and "install" - real
      # install()'s empty fixed/check_arg slots keep their separators. (The
      # msg's apt-get prefix is the RESOLVED binary path - the shim here,
      # /usr/bin/apt-get on a real host.)
      result["msg"].as_s.must_include(
        "-o \"Dpkg::Options::=--force-confdef\" -o \"Dpkg::Options::=--force-confold\" -o DPkg::Lock::Timeout=60       install 'bash=5.2-1'' failed: E: Unable to correct problems"
      )
      # The shim logs the shell-unquoted argv; the msg carries the quoted one.
      File.read(log).must_include("install bash=5.2-1")
      # Real's failure data: msg, stdout, stderr, rc, cache keys, *_lines.
      result["rc"].as_i.must_equal(100)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("E: Unable to correct problems, you have held broken packages.\n")
      result["stdout_lines"].as_a.size.must_equal(0)
      result["stderr_lines"].as_a.size.must_equal(1)
      result.as_h.has_key?("cache_update_time").must_equal(true)
      result["cache_updated"].as_bool.must_equal(false)
      # kwargs-first fail_json order, as the state=present failure emits.
      result.as_h.keys.first(9).must_equal([
        "stdout", "stderr", "rc", "cache_updated", "cache_update_time",
        "failed", "msg", "stdout_lines", "stderr_lines",
      ])
    end
  end
end

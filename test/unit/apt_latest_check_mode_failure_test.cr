require "../minitest_helper"
require "file_utils"

# Issue #1364 (monsieurbiz.blackfire, round 29913645): the role's
# "Install PHP-FPM and packages" loop installs prebuilt dotdeb php7.0
# packages, whose candidates exist but whose dependencies the host cannot
# satisfy. Ansible's install() still runs the check-mode
# `apt-get ... --simulate install '<name>=<version>'` command and fails
# the task on apt-get's rc=100 ("E: Unable to correct problems, you have
# held broken packages"), loop item after loop item; this engine's
# check-mode branch piped the simulate run through `grep '^Inst'` and
# judged only grep's exit status, which is 1 both for a clean no-op and
# for a failed apt-get - so every item came back
# "already at latest version"/ok.
#
# The plugin is driven through the real plugin binary with fake
# `apt-cache`/`dpkg-query`/`apt-get` shims on PATH (the
# apt_latest_failure_shape_test.cr pattern - no process-wide ENV
# mutation). The apt-get shim always fails rc=100 while logging its argv.
private def with_apt_check_mode_failure_shims(&)
  dir = PluginSpecHelper.tmp_path("fake-apt-check-mode-failure")
  log = PluginSpecHelper.tmp_path("apt-get-check-mode-failure-invocations")
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
    echo "$@" >> "#{log}"
    echo "E: Unable to correct problems, you have held broken packages." >&2
    exit 100
    SH
  ["apt-cache", "dpkg-query", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "apt state=latest check-mode simulate failure (issue 1364)" do
  it "fails with install()'s --simulate command and full failure data" do
    with_apt_check_mode_failure_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"                => "bash",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      # Real install()'s check_arg slot carries --simulate, the empty
      # fixed/only_upgrade/force/autoremove/no-remove slots keep their
      # separators, and the spec carries its resolved candidate version.
      result["msg"].as_s.must_include(
        "-o \"Dpkg::Options::=--force-confdef\" -o \"Dpkg::Options::=--force-confold\" -o DPkg::Lock::Timeout=60      --simulate install 'bash=5.2-1'' failed: E: Unable to correct problems, you have held broken packages."
      )
      File.read(log).must_include("--simulate install bash=5.2-1")
      result["rc"].as_i.must_equal(100)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("E: Unable to correct problems, you have held broken packages.\n")
      result["stdout_lines"].as_a.size.must_equal(0)
      result["stderr_lines"].as_a.size.must_equal(1)
      result.as_h.has_key?("cache_update_time").must_equal(true)
      result["cache_updated"].as_bool.must_equal(false)
      result.as_h.keys.first(9).must_equal([
        "stdout", "stderr", "rc", "cache_updated", "cache_update_time",
        "failed", "msg", "stdout_lines", "stderr_lines",
      ])
    end
  end
end

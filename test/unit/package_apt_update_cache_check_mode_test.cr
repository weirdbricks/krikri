require "../minitest_helper"
require "file_utils"

# Issue #1831 (bodsch.harbor, round round29927187): a check-mode
# `package: {update_cache: true}` task reported `ok` where real
# ansible-playbook reported `changed`. `package:` delegates to apt.py on
# Debian hosts, and apt.py's cache pass skips `cache.update()` under check
# mode while still claiming the refresh once it was DUE (`if
# module.check_mode or updated_cache_time != post_cache_update_time`), so
# the cache-only exit is always changed=true there. This module instead ran
# the real `apt-get update` in check mode - a persistent mutation that also
# decided `changed` from the lists-dir mtime, which an all-Hit update leaves
# untouched (the `ok` krikri printed in the round).
private def with_apt_update_cache_shims(&)
  dir = PluginSpecHelper.tmp_path("fake-apt-update-cache")
  Dir.mkdir_p(dir)
  log_path = File.join(dir, "apt-get.log")

  # The python3-apt probe runs the pinned interpreter by absolute path (so
  # PATH cannot reach it); pinning `ansible_python_interpreter` at this shim
  # keeps the spec independent of whether the host running the suite has the
  # bindings installed.
  File.write(File.join(dir, "python3"), "#!/bin/sh\nexit 0\n")
  File.chmod(File.join(dir, "python3"), 0o755)

  File.write(File.join(dir, "apt-get"), <<-SH)
    #!/bin/sh
    echo "$*" >> #{log_path}
    echo "Reading package lists..."
    echo "Building dependency tree..."
    exit 0
    SH
  File.chmod(File.join(dir, "apt-get"), 0o755)

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env, dir, log_path
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "package: apt update_cache check-mode changed flag (issue 1831)" do
  it "reports changed like apt.py without running apt-get update" do
    with_apt_update_cache_shims do |env, dir, log_path|
      result = PluginSpecHelper.run("package", {
        "update_cache"        => "true",
        "use"                 => "apt",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      }, {"ansible_python_interpreter" => File.join(dir, "python3")})

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      # Check mode must not touch the target's apt state at all.
      File.exists?(log_path).must_equal(false)
    end
  end

  it "still refreshes the cache and decides changed by the mtime outside check mode" do
    with_apt_update_cache_shims do |env, dir, log_path|
      result = PluginSpecHelper.run("package", {
        "update_cache" => "true",
        "use"          => "apt",
        "_environment" => env,
      }, {"ansible_python_interpreter" => File.join(dir, "python3")})

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      # The shimmed update leaves every real lists-dir mtime untouched, which
      # is the all-Hit no-op apt.py also reports as changed=false.
      result["changed"].as_bool.must_equal(false)
      log = File.exists?(log_path) ? File.read(log_path) : ""
      log.lines.map(&.strip).reject(&.empty?).must_equal(["update"])
    end
  end
end

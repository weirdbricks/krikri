require "../spec_helper"
require "file_utils"

# Regression spec for `apt`'s `name: pkg=version` pin handling (round 76017,
# dj-wasabi.telegraf): `name: telegraf=1.18.2-1` where that exact version
# doesn't exist in the configured repos. Real apt-get hard-fails with
# "E: Version '1.18.2-1' for 'telegraf' was not found" (exit 100) and real
# Ansible propagates that as a task failure; this engine previously let the
# task "succeed" and only failed later on whatever the never-installed
# package's own files were missing.

# Builds a stub PATH dir whose `apt-get` logs every invocation to
# $KRIKRI_APT_CALLS and answers an install of an explicitly pinned
# non-existent version ($KRIKRI_APT_BAD_PIN, "name=version") with real
# apt-get's own version-not-found failure shape (exit 100, the E: line on
# stderr); any other invocation exits 0. `stat` reports a static mtime so
# the cache-update probe never sees movement. Yields the `_environment`
# JSON param and the call-log path.
private def with_bad_pin_shim(bad_pin : String, &)
  dir = File.join(Dir.tempdir, "krikri-apt-pin-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    case "$*" in
      *$KRIKRI_APT_BAD_PIN*)
        echo "E: Version '${KRIKRI_APT_BAD_PIN#*=}' for '${KRIKRI_APT_BAD_PIN%%=*}' was not found" >&2
        exit 100
        ;;
    esac
    exit 0
  SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_APT_CALLS" => log, "KRIKRI_APT_BAD_PIN" => bad_pin}.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin pinned-version validation" do
  it "propagates apt-get's version-not-found failure for a pinned version that doesn't exist" do
    with_bad_pin_shim("pkgname=badversion") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "pkgname=badversion",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("not found")
      File.read(log).should contain("pkgname=badversion")
    end
  end
end

require "../spec_helper"
require "file_utils"

# Regression spec for `apt`'s `name: pkg=version` pin handling (round 76017,
# dj-wasabi.telegraf): `name: telegraf=1.18.2-1` where that exact version
# doesn't exist in the configured repos. Real package_status()'s
# version_installable probe (python-apt cache lookup, no apt-get involved)
# fails the task up front with "no available installation candidate for
# <spec>"; this engine previously let the task reach `apt-get install`
# (which hard-fails "E: Version '...' was not found", exit 100) and only
# reported a wrapped "Failed to install ..." msg - and an even older
# engine let the never-installed package "succeed" and fail later on its
# own missing files instead.

# Builds a stub PATH dir whose `apt-get` logs every invocation to
# $KRIKRI_APT_CALLS and answers an install of an explicitly pinned
# non-existent version ($KRIKRI_APT_BAD_PIN, "name=version") with real
# apt-get's own version-not-found failure shape (exit 100, the E: line on
# stderr); any other invocation exits 0. `apt-cache` (the candidate
# pre-flight probe's resolution source, standing in for real's in-process
# python-apt cache) reports a candidate version that is NOT the bad pin,
# so the pin is what fails. `stat` reports a static mtime so the
# cache-update probe never sees movement. Yields the `_environment` JSON
# param and the call-log path.
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
  File.write(File.join(dir, "apt-cache"), <<-'CACHE_SHIM')
    #!/bin/sh
    printf 'pkgname:\n  Installed: (none)\n  Candidate: 1.0-1\n  Version table:\n     1.0-1 500\n'
  CACHE_SHIM
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "apt-cache"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_APT_CALLS" => log, "KRIKRI_APT_BAD_PIN" => bad_pin}.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin pinned-version validation" do
  # Real package_status()'s version_installable probe rejects a pin with
  # no candidate BEFORE any apt-get invocation, with its own wording -
  # apt-get's "E: Version '...' was not found" is never reached (this
  # engine used to defer the failure to apt-get and wrap it in a
  # "Failed to install ...: <stderr>" msg instead).
  it "fails the candidate pre-flight with real's wording for a pinned version that doesn't exist" do
    with_bad_pin_shim("pkgname=badversion") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "pkgname=badversion",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("no available installation candidate for pkgname=badversion")
      # The pre-flight rejects the pin before apt-get ever runs.
      install_calls = File.exists?(log) ? File.read_lines(log).select(&.starts_with?("install")) : [] of String
      install_calls.empty?.should be_true
    end
  end
end

require "../minitest_helper"
require "file_utils"
require "json"

# A `NAME=VER` pin whose version does NOT match what dpkg has installed:
# apt.py's package_status() asks "is the installed version satisfactory
# for this spec" (fnmatch of the installed version against the pin), so
# `NAME=1.0` on a host with NAME 9.9 installed is NOT already-satisfied -
# install() proceeds to its own candidate resolution and fails with
# "no available installation candidate for NAME=VER" before apt-get runs
# (live-verified against ansible-playbook 2.19, libssl-dev=1.0.2k-1~bpo8+
# on a host with a newer libssl-dev - AAROC.AAROC_fg-api, issue #1128).
# The installed check used to match on the base NAME alone, so the same
# task reported ok and satisfied nothing. Check mode fails the same way,
# with the cache keys real carries on this failure (the simulate run's
# stderr is folded into stdout via 2>&1, so the E: line lives there).
#
# The plugin binary is exercised for real against shimmed dpkg-query/
# apt-get/apt-mark on PATH (same pattern as
# package_apt_absent_mixed_test.cr, whose helper shape is copied rather
# than required - the installed check lives inside the plugin file whose
# bottom-of-file entry point defeats a plain require).

PIN_MISMATCH_NAME = "krikri-pkg-pin-1128"
PIN_MISMATCH_PIN  = "1.0"

private def with_pinned_mismatch_shims(shim_dir : String, &)
  Dir.mkdir_p(shim_dir)
  # dpkg-query reports the base name installed at a version the pin does
  # not match; apt-get fails the install exactly the way apt reports an
  # unresolvable pin; apt-mark succeeds so the pre-fix path (which
  # reached the trailing mark as an all-already-satisfied no-op) would
  # have returned a clean ok here.
  dq_script = <<-SH
    #!/bin/sh
    for a in "$@"; do
      if [ "$a" = "#{PIN_MISMATCH_NAME}" ]; then
        printf 'ii  9.9-1 %s\\n' "$a"
      fi
    done
    SH
  File.write("#{shim_dir}/dpkg-query", dq_script)
  File.chmod("#{shim_dir}/dpkg-query", 0o755)
  File.write("#{shim_dir}/apt-get", <<-SH
    #!/bin/sh
    cat <<'KRIKRI_FAKE_APT_EOF' >&2
    E: Version '#{PIN_MISMATCH_PIN}' for '#{PIN_MISMATCH_NAME}' was not found
    KRIKRI_FAKE_APT_EOF
    exit 100
    SH
  )
  File.chmod("#{shim_dir}/apt-get", 0o755)
  File.write("#{shim_dir}/apt-mark", "#!/bin/sh\nexit 0\n")
  File.chmod("#{shim_dir}/apt-mark", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "package:/apt version pin vs installed version mismatch" do
  serial!

  it "fails an unsatisfied pin instead of reporting the base name installed" do
    with_pinned_mismatch_shims(PluginSpecHelper.tmp_path("pin-mismatch-shims")) do
      result = PluginSpecHelper.run("package",
        {"name" => "#{PIN_MISMATCH_NAME}=#{PIN_MISMATCH_PIN}", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("no available installation candidate for #{PIN_MISMATCH_NAME}=#{PIN_MISMATCH_PIN}")
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "fails the same pin in check mode with the cache keys real carries" do
    with_pinned_mismatch_shims(PluginSpecHelper.tmp_path("pin-mismatch-check-shims")) do
      result = PluginSpecHelper.run("package",
        {"name" => "#{PIN_MISMATCH_NAME}=#{PIN_MISMATCH_PIN}", "state" => "present", "use" => "apt",
         "_ansible_check_mode" => "true"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("no available installation candidate for #{PIN_MISMATCH_NAME}=#{PIN_MISMATCH_PIN}")
      result["cache_updated"].as_bool.must_equal(false)
      result.as_h.has_key?("cache_update_time").must_equal(true)
    end
  end

  # apt.py claims updated_cache unconditionally in check mode once the
  # refresh was due (`if module.check_mode or updated_cache_time !=
  # post_cache_update_time: updated_cache = True`) - the update itself is
  # skipped, but every result main() decorates with the cache keys carries
  # cache_updated: true (live-verified vs ansible-playbook --check with
  # update_cache: true, AAROC.AAROC_fg-api's "Ensure system prerequisites"
  # failure line, issue #1142).
  it "claims the due cache refresh on the check-mode pin failure like real" do
    with_pinned_mismatch_shims(PluginSpecHelper.tmp_path("pin-mismatch-check-due-shims")) do
      result = PluginSpecHelper.run("package",
        {"name" => "#{PIN_MISMATCH_NAME}=#{PIN_MISMATCH_PIN}", "state" => "present", "use" => "apt",
         "update_cache" => "true", "_ansible_check_mode" => "true"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("no available installation candidate for #{PIN_MISMATCH_NAME}=#{PIN_MISMATCH_PIN}")
      result["cache_updated"].as_bool.must_equal(true)
    end
  end
end

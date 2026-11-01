require "../minitest_helper"
require "file_utils"

# Issue #449 (ccdc.cpp_gui_dev_tools): real apt.py wraps EVERY apt command
# in its module-wide run_command_environ_update - DEBIAN_FRONTEND/
# DEBIAN_PRIORITY plus LANG/LC_ALL/LC_MESSAGES/LC_CTYPE/LANGUAGE all set to
# get_best_parsable_locale's result, which runs `locale -a` on the target
# and prefers C.utf8/C.UTF-8 over plain 'C'. This engine used to hardcode
# `LANGUAGE=C LC_ALL=C` into the command string, and the difference is
# observable in registered output: systemd's "Created symlink" message
# prints the UTF-8 arrow only under a UTF-8 locale, plain "->" under 'C',
# so a failed big install's captured stdout diverged from Ansible's byte
# for byte (verified live in a podman ubuntu:22.04 container against
# ansible-core 2.19.11: every "Created symlink ... → ..." line became
# "Created symlink ... -> ...").

private def with_apt_locale_shims(available_locales : String, &)
  dir = PluginSpecHelper.tmp_path("fake-apt-locale-#{Random.rand(1_000_000)}")
  log = PluginSpecHelper.tmp_path("apt-locale-env-#{Random.rand(1_000_000)}")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  # `locale -a` answers with the given locale list; anything else fails the
  # way a missing/limited locale tool would.
  File.write(File.join(dir, "locale"), "#!/bin/sh\nif [ \"$1\" = \"-a\" ]; then printf '#{available_locales}'; exit 0; fi\nexit 1\n")
  File.write(File.join(dir, "apt-cache"), "#!/bin/sh\n[ -n \"$2\" ] || exit 0\nprintf '%s:\\n  Installed: (none)\\n  Candidate: 1.0-1\\n  Version table:\\n' \"$2\"\n")
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\necho \"un 1.0-1 $3\"\n")
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  # The install itself fails (rc 100, the dpkg-error shape issue #449 ran
  # into) - the env the command ran under is the thing under test, so the
  # shim records it before failing.
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\nprintf '%s|%s\\n' \"$LC_ALL\" \"$DEBIAN_PRIORITY\" >> \"#{log}\"\necho \"E: Sub-process /usr/bin/dpkg returned an error code (1)\" >&2\nexit 100\n")
  ["locale", "apt-cache", "dpkg-query", "stat", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
    File.delete(log) if File.exists?(log)
  end
end

describe "apt module locale environment (issue 449)" do
  it "runs apt-get under ansible's probed C.utf8 locale, not hardcoded C" do
    with_apt_locale_shims("C\nC.utf8\nPOSIX\n") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "nginx",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.includes?("E: Sub-process /usr/bin/dpkg returned an error code (1)").must_equal(true)
      # get_best_parsable_locale's first preference that `locale -a` offers
      # wins (C.utf8, not C.UTF-8 - Python checks the lowercase spelling
      # first) and DEBIAN_PRIORITY=critical rides along as apt.py sets it.
      File.read(log).strip.must_equal("C.utf8|critical")
    end
  end

  it "falls back to plain C when the target offers no UTF-8 locale" do
    with_apt_locale_shims("C\nPOSIX\n") do |env, log|
      PluginSpecHelper.run("apt", {
        "name"         => "nginx",
        "state"        => "present",
        "_environment" => env,
      })

      File.read(log).strip.must_equal("C|critical")
    end
  end
end

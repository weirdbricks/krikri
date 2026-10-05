require "../minitest_helper"

# Pins plugins/timezone.cr's backend-init ordering against real
# community.general.timezone 2.19.11's NosystemdTimezone.__init__:
#
#   1. _verify_timezone() runs FIRST - a planned zone that has no
#      /usr/share/zoneinfo entry fails with the module's own wrapped
#      abort() text, even when the task also asks for an hwclock change
#      and the host has no hwclock binary at all.
#   2. The helper binaries are resolved next (cp, then hwclock, then the
#      Debian branch's ln), and a missing one fails through
#      module_utils' get_bin_path - i.e. WITHOUT the "Error message:"
#      wrapper, which only the zone check and command failures use.
#
# Live-diffed vs ansible-playbook through the kpg32 generator sweep
# (12/15 timezone playbooks) and a local ansible_connection=local repro
# against a host without hwclock.
describe "timezone plugin backend init ordering" do
  # module_utils' get_bin_path search space: PATH plus the sbin dirs
  # that exist (which is why getcap/hwclock in /usr/sbin still count).
  def binary_path(name : String) : String?
    paths = (ENV["PATH"]? || "").split(':')
    {"/sbin", "/usr/sbin", "/usr/local/sbin"}.each do |dir|
      paths << dir if !paths.includes?(dir) && Dir.exists?(dir)
    end
    paths.each do |dir|
      candidate = File.join(dir, name)
      return candidate if File.exists?(candidate) && !File.directory?(candidate) && File::Info.executable?(candidate)
    end
    nil
  end

  # Timezone.__new__ on Linux picks SystemdTimezone whenever a
  # `timedatectl` is found AND exits 0 - and only that backend ever
  # resolves hwclock at all.
  def nosystemd_backend? : Bool
    timedatectl = binary_path("timedatectl")
    return true unless timedatectl
    !Process.run(timedatectl, output: IO::Memory.new, error: Process::Redirect::Close).success?
  end

  it "verifies the planned zone before resolving hwclock" do
    result = PluginSpecHelper.run("timezone", {"name" => "Krikri/NoSuchZone", "hwclock" => "local"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error message:\ngiven timezone \"Krikri/NoSuchZone\" is not available")
  end

  it "keeps the wrapped zone error for a name-only task" do
    result = PluginSpecHelper.run("timezone", {"name" => "Krikri/NoSuchZoneEither"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error message:\ngiven timezone \"Krikri/NoSuchZoneEither\" is not available")
  end

  it "reports a missing hwclock unwrapped, without the abort() header" do
    skip "host has hwclock installed, so real resolves the binary" if binary_path("hwclock")
    skip "host's timedatectl is usable, so real picks the systemd backend" unless nosystemd_backend?

    result = PluginSpecHelper.run("timezone", {"hwclock" => "local"})

    result["failed"].as_bool.must_equal(true)
    msg = result["msg"].as_s
    msg.starts_with?("Failed to find required executable \"hwclock\" in paths: ").must_equal(true)
    msg.includes?("Error message:").must_equal(false)
  end
end

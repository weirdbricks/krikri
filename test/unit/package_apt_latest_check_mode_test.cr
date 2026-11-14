require "../minitest_helper"
require "file_utils"

# Issue #1262 (onelove-roles.freebsd_node, round 29910501): `package:`
# with `state: latest` on an apt host reported `changed` in check mode
# for a package already at the newest version, where ansible-playbook
# said `ok`. The check-mode branch matched the word "upgrade" anywhere
# in apt-get's simulate output - and every simulate run ends with the
# always-present "0 upgraded, 0 newly installed, ... and 0 not upgraded"
# summary line, so the task could never converge. Ansible's install()
# only counts a change when it has at least one spec to install, i.e.
# when the simulate run emits an `Inst ...` action line.
private def with_apt_simulate_shim(stdout : String, &)
  dir = PluginSpecHelper.tmp_path("fake-apt-simulate")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\ncat <<'KRIKRI_FAKE_APT_EOF'\n#{stdout}\nKRIKRI_FAKE_APT_EOF\nexit 0\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "package:/apt check-mode state: latest changed flag (issue 1262)" do
  it "reports ok when the simulate run only carries apt's zero-change summary" do
    with_apt_simulate_shim(
      "NOTE: This is only a simulation!\nReading package lists...\nBuilding dependency tree...\nReading state information...\nnpm is already the newest version (9.2.0~ds1-3).\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
    ) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "npm",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "use"                 => "apt",
        "_environment"        => env,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Package npm already at latest version (check mode)")
    end
  end

  it "reports changed when the simulate run lists an Inst action" do
    with_apt_simulate_shim(
      "NOTE: This is only a simulation!\nReading package lists...\nBuilding dependency tree...\nReading state information...\nInst npm [9.2.0~ds1-3] (9.2.0~ds1-4 Debian:13.7/stable [all])\n0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded."
    ) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "npm",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "use"                 => "apt",
        "_environment"        => env,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Would upgrade npm to latest (check mode)")
    end
  end
end

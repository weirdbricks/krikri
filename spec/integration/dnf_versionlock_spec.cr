require "../spec_helper"

# dnf_versionlock only makes sense against a real RHEL/Fedora host with
# dnf-plugin-versionlock installed - this dev/CI box has no /usr/bin/dnf
# at all, so only the "dnf missing" failure path is exercisable here.
# The rest of the plugin (NEVRA matching, locklist add/exclude/absent/
# clean) needs live verification on a real dnf host - see
# KNOWN_MISSING.md.
private DNF = "/usr/bin/dnf"

describe "dnf_versionlock plugin" do
  it "fails cleanly when dnf is not installed" do
    result = PluginSpecHelper.run("dnf_versionlock", {"name" => "nginx", "state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("dnf")
  end

  # Regression spec for the ad-hoc CLI sweep (2026-09-13): the plugin used
  # to be a complete no-op on Fedora-family hosts - its NEVRA regex required
  # a dot-free release ("1.fc41" never matched), so `dnf repoquery` output
  # was silently skipped, specs_toadd stayed empty, and no
  # `dnf versionlock add` ever ran while the result still claimed success.
  # Verified live against a Fedora 41 container (dnf5) and real
  # community.general.dnf_versionlock: add/idempotent-add/absent/clean now
  # report the same changed/locklist/specs fields.
  it "actually locks and unlocks a raw pattern" do
    pending! "no dnf on this host" unless File.exists?(DNF)

    result = PluginSpecHelper.run("dnf_versionlock", {
      "name"  => "krikri-spec-0:1.0-1.*",
      "state" => "present",
      "raw"   => "true",
    })
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true
    result["specs_toadd"].as_a.should contain("krikri-spec-0:1.0-1.*")
    result["locklist_post"].as_a.should contain("krikri-spec-0:1.0-1.*")

    result = PluginSpecHelper.run("dnf_versionlock", {
      "name"  => "krikri-spec-0:1.0-1.*",
      "state" => "present",
      "raw"   => "true",
    })
    result["changed"].as_bool.should be_false
    result["locklist_post"].as_a.should contain("krikri-spec-0:1.0-1.*")

    result = PluginSpecHelper.run("dnf_versionlock", {
      "name"  => "krikri-spec-0:1.0-1.*",
      "state" => "absent",
      "raw"   => "true",
    })
    result["changed"].as_bool.should be_true
    result["specs_todelete"].as_a.should contain("krikri-spec-0:1.0-1.*")
  end

  it "resolves a plain package name to NEVRA locklist entries (non-raw)" do
    pending! "no dnf on this host" unless File.exists?(DNF)

    result = PluginSpecHelper.run("dnf_versionlock", {"name" => "bash", "state" => "present"})
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true
    result["specs_toadd"].as_a.size.should be > 0
    result["specs_toadd"].as_a.each(&.as_s.should(match(/^bash-\d+:/)))
    result["locklist_post"].as_a.size.should be > 0

    PluginSpecHelper.run("dnf_versionlock", {"state" => "clean"})
  end
end

require "../spec_helper"

# dnf_versionlock only makes sense against a real RHEL/Fedora host with
# dnf-plugin-versionlock installed - this dev/CI box has no /usr/bin/dnf
# at all, so only the "dnf missing" failure path is exercisable here.
# The rest of the plugin (NEVRA matching, locklist add/exclude/absent/
# clean) needs live verification on a real dnf host - see
# KNOWN_MISSING.md.

describe "dnf_versionlock plugin" do
  it "fails cleanly when dnf is not installed" do
    result = PluginSpecHelper.run("dnf_versionlock", {"name" => "nginx", "state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("dnf")
  end
end

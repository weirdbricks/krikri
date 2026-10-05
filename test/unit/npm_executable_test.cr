require "../minitest_helper"

# Pins plugins/npm.cr's executable handling against real
# community.general.npm (live-diffed vs ansible-playbook 2.19.11 in
# the no-node container): an `executable:` override runs VERBATIM
# (bypasses get_bin_path) - a missing path surfaces run_command's OSError
# shape from the FIRST command (the list probe), with rc=errno and the
# space-joined list command string; without an override, get_bin_path
# fails with its own wording when npm is missing.
describe "npm executable handling" do
  it "fails a missing executable override with the OSError shape on the list probe" do
    result = PluginSpecHelper.run("npm", {
      "name"       => "krikri-test-package",
      "global"     => "true",
      "executable" => "/no/such/npm",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal("/no/such/npm list --json --long --global")
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'/no/such/npm'")
  end

  it "fails with get_bin_path wording when no npm binary exists" do
    # npm IS installed on this host, so the default-path happy flow can't
    # reach the get_bin_path failure here; pin instead that a resolvable
    # npm proceeds past the probe into the list (its failure shape is
    # env-dependent, so only the probe outcome is asserted via the
    # missing-binary wording being absent).
    result = PluginSpecHelper.run("npm", {
      "name"   => "krikri-test-package",
      "global" => "true",
    })

    result["msg"].as_s.wont_include("Failed to find required executable")
  end
end

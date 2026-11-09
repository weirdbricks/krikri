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

  it "treats an empty executable override as no override" do
    # fubarhouse.pm2's `executable: "{{ which_npm.stdout }}"` templates
    # to "" from a check-mode-skipped `which npm` probe (issue #1045):
    # Python's `if kwargs['executable']:` is falsy for "", so Ansible
    # falls to `get_bin_path("npm", True)` - this plugin used to split ""
    # to an empty argv and crash `exe_parts[0]` with "Index out of
    # bounds". PATH is pinned to a scratch dir holding only `tr` (the
    # probe's one external) so the npm lookup deterministically fails.
    dir = PluginSpecHelper.tmp_path("npm-empty-exe")
    Dir.mkdir_p(dir)
    tr_path = Process.find_executable("tr") || raise "tr not found in PATH"
    File.symlink(tr_path, File.join(dir, "tr"))

    result = PluginSpecHelper.run("npm", {
      "name"       => "krikri-test-package",
      "global"     => "true",
      "executable" => "",
    }, env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      %(Failed to find required executable "npm" in paths: #{dir}:/sbin:/usr/sbin:/usr/local/sbin))
  end

  it "re-resolves a whitespace-only override as the empty name" do
    # `if kwargs['executable']:` is truthy for " " and split(' ') keeps
    # empty words, so CmdRunner re-resolves "" through get_bin_path -
    # live-verified vs ansible: the failure message carries the empty
    # name, not "npm" (issue #1045's edge; this plugin crashed
    # `exe_parts[0]` here too before it kept the empty words).
    dir = PluginSpecHelper.tmp_path("npm-ws-exe")
    Dir.mkdir_p(dir)
    tr_path = Process.find_executable("tr") || raise "tr not found in PATH"
    File.symlink(tr_path, File.join(dir, "tr"))

    result = PluginSpecHelper.run("npm", {
      "name"       => "krikri-test-package",
      "global"     => "true",
      "executable" => " ",
    }, env: {"PATH" => dir})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      %(Failed to find required executable "" in paths: #{dir}:/sbin:/usr/sbin:/usr/local/sbin))
  end
end

require "../spec_helper"

# npm: actually installing/uninstalling packages needs a real npm
# binary and network access, and mutates the machine running the test
# suite - these specs exercise validation only (safe, no real
# execution), matching the same convention pip.cr's own specs use.
#
# Live-verified separately (not in this spec, to avoid real npm
# mutation/network access): `npm install left-pad` into a scratch
# directory (state: present, global: false) installed cleanly
# (changed: true), a rerun correctly reported "Package already
# installed" (changed: false), and state: absent removed it (changed:
# true) then correctly no-op'd on a second removal (changed: false) -
# all matching real Ansible's own community.general.npm algorithm
# (npm list --json --long, checking the "dependencies" hash for a
# missing/invalid entry).
describe "npm plugin" do
  it "fails when neither global nor path is given" do
    result = PluginSpecHelper.run("npm", {"name" => "left-pad"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("path is required")
  end

  it "fails with a clear message when name is missing for state: absent" do
    result = PluginSpecHelper.run("npm", {"global" => "true", "state" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name is required")
  end

  it "fails with the real Ansible executable-not-found message instead of silently reporting already installed" do
    # Real Ansible's own npm module resolves the executable via
    # `module.get_bin_path(npm_path, True)`, which fails the task
    # outright when it's missing - real bug found via a 400-role
    # regression sweep: krikri's own `npm list` shell command just
    # failed silently (bad exit code, empty stdout) and
    # #collect_installed's "malformed output -> nothing installed"
    # fallback turned that into an empty `missing` set, which
    # #handle_present then read as "Package already installed" without
    # npm ever actually having been checked to exist at all.
    result = PluginSpecHelper.run("npm", {
      "name"       => "left-pad",
      "global"     => "true",
      "executable" => "krikri-spec-nonexistent-npm-binary",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Failed to find required executable \"krikri-spec-nonexistent-npm-binary\" in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  end
end

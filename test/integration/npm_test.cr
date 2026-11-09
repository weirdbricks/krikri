require "../minitest_helper"

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
# all matching Ansible's own community.general.npm algorithm
# (npm list --json --long, checking the "dependencies" hash for a
# missing/invalid entry).
describe "npm plugin" do
  it "fails when neither global nor path is given" do
    result = PluginSpecHelper.run("npm", {"name" => "left-pad"})

    result["failed"].as_bool.must_equal(true)
    # The sweep environment's community.general (11.2.1, Debian trixie's
    # ansible package) checks path as a module-level explicit check in
    # main(), right after arg-spec validation (the 13.x required_if
    # wording is NOT what the sweep's real container runs).
    result["msg"].as_s.must_equal("path must be specified when not using global")
  end

  it "fails with a clear message when name is missing for state: absent" do
    result = PluginSpecHelper.run("npm", {"global" => "true", "state" => "absent"})

    result["failed"].as_bool.must_equal(true)
    # Real community.general.npm's own required_if wording:
    # ("state", "absent", ["name"]).
    result["msg"].as_s.must_equal("state is absent but all of the following are missing: name")
  end

  it "fails with the Ansible executable-not-found message instead of silently reporting already installed" do
    # Ansible's own npm module resolves the executable via
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

    result["failed"].as_bool.must_equal(true)
    # The searched-paths tail is the target's own $PATH (plus the sbin
    # dirs real appends when missing) - env-dependent; pin the wording
    # and the name.
    result["msg"].as_s.must_include(
      "Failed to find required executable \"krikri-spec-nonexistent-npm-binary\" in paths: ")
  end

  it "fails an executable: PATH override with the OSError shape, not the get_bin_path wording" do
    # Real npm runs an `executable:` path VERBATIM (bypasses
    # get_bin_path; CmdRunner only re-resolves a bare name), so a
    # missing path surfaces as run_command's OSError shape from the
    # FIRST command (the list probe) - live-verified vs 2.19.11: msg
    # "Error executing command.", rc 2, the [Errno] exception text
    # composing the display chain, cmd echoing the space-joined list
    # command (podman-diff npm_edge_cases N7).
    result = PluginSpecHelper.run("npm", {
      "name"       => "left-pad",
      "global"     => "true",
      "executable" => "/nonexistent-krikri-npm",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal("/nonexistent-krikri-npm list --json --long --global")
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'/nonexistent-krikri-npm'")
  end

  it "check mode predicts changed without running the install" do
    # Ansible's _exec gate runs only the list probe in check mode:
    # `npm install`/`uninstall` are predicted from the installed-set
    # check but never started (live-verified vs ansible - `changed:`,
    # nothing executes). A stub npm logs every command it receives so
    # the spec pins that the mutating command never ran; real npm
    # mutation has no suite coverage by design (see this file's header).
    dir = PluginSpecHelper.tmp_path("npm-check-mode")
    Dir.mkdir_p(dir)
    log = File.join(dir, "commands.log")
    stub = File.join(dir, "npm")
    File.write(stub, <<-SH)
      #!/bin/sh
      echo "$@" >> #{Process.quote(log)}
      echo '{"dependencies":{}}'
      SH
    File.chmod(stub, 0o755)

    result = PluginSpecHelper.run("npm", {
      "name"                => "krikri-test-package",
      "global"              => "true",
      "executable"          => stub,
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(log).must_equal("list --json --long --global\n")
  end
end

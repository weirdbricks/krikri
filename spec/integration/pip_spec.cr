require "../spec_helper"

# pip: actually installing/uninstalling packages needs a real pip
# binary and network access, and mutates the machine running the test
# suite - these specs exercise validation only (safe, no real
# execution), matching the same convention apt.cr's own fixes use
# (spec/integration/apt_repository_spec.cr's own comment, and
# haproxy-certbot-benchmark-round.md's documented rationale for why
# cron.cr's user-crontab path has no spec either).
describe "pip plugin" do
  it "fails with a clear message when neither name nor requirements is given" do
    result = PluginSpecHelper.run("pip", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name or requirements")
  end

  it "no-ops cleanly when name: is present but resolves to an empty list" do
    # Round 131 (robertdebock.vagrant): name: "{{ vagrant_pip_packages }}"
    # resolving to an empty list rendered as the literal text "[]" -
    # real Ansible's pip.py treats `if name:` as Python truthiness, so
    # an empty list is not an error, it falls through to the same
    # "nothing to do" branch as name: omitted, exiting changed: false.
    result = PluginSpecHelper.run("pip", {"name" => "[]"})

    result["failed"]?.try(&.as_bool).should_not be_true
    result["changed"].as_bool.should be_false
  end

  it "unwraps a single-element name: list to the bare package name" do
    # state: absent on a not-installed package only ever calls `pip
    # show` (no real install/network call) - safe to run for real,
    # matching this file's own no-real-execution convention.
    result = PluginSpecHelper.run("pip", {
      "name"  => "['definitely-not-a-real-package-xyz']",
      "state" => "absent",
    })

    result["failed"]?.try(&.as_bool).should_not be_true
    result["msg"].as_s.should_not contain("[")
  end

  it "strips a PEP 508 extras suffix before checking pip show (regression: robertdebock.ara round 144 - pip show 'ara[server]' fails outright, extras aren't a separate installed distribution)" do
    # state: absent on a not-installed package only ever calls `pip
    # show` (no real install/network call) - safe to run for real.
    # Before the fix, `pip show 'definitely-not-a-real-package-xyz[extra]'`
    # would have been shelled out with the extras suffix intact (pip
    # itself rejects that form outright), and any `name: "pkg[extra]"`
    # install task would never converge to changed: false.
    result = PluginSpecHelper.run("pip", {
      "name"  => "definitely-not-a-real-package-xyz[extra]",
      "state" => "absent",
    })

    result["failed"]?.try(&.as_bool).should_not be_true
    result["changed"].as_bool.should be_false
  end

  # Real bug found benchmarking konstruktoid.docker_rootless (0.9.616):
  # `name: [docker, "urllib3<2"]` (a literal YAML list) reaches this
  # plugin already comma-joined by the parser ("docker,urllib3<2") -
  # checked here as ONE bogus "package" via `pip show
  # docker,urllib3<2`, which always fails, so the idempotency
  # short-circuit could never succeed and a warm rerun always reported
  # changed: true even when every package was already installed.
  # Separately (not spec-covered here - would need a real network
  # install - see this file's own no-real-execution convention above),
  # the unescaped `<` in the same comma-joined string reached a
  # `bash -c` pip-install invocation as a literal shell metacharacter,
  # redirecting stdin from a nonexistent file named "2" instead of
  # being part of the package spec - verified live against the real
  # host that found it.
  it "checks each comma-joined package independently for the already-installed idempotency short-circuit" do
    # "pip" is always present in a working pip environment - safe (pip
    # show only, no install/network) - listed twice to exercise the
    # per-package split this fix introduced without depending on which
    # OTHER packages happen to be installed in the sandbox running specs.
    result = PluginSpecHelper.run("pip", {"name" => "pip,pip"})

    result["failed"]?.try(&.as_bool).should_not be_true
    result["changed"].as_bool.should be_false
  end

  describe "umask:" do
    # Real bug found via a proactive scope-cut audit: umask: was
    # entirely unimplemented. Verified against real
    # ansible/modules/pip.py's own source, including its exact "umask
    # must be an octal integer" validation message - matched verbatim.
    # Live-verified separately (not in this spec, to avoid real pip
    # mutation/network access, matching this file's own established
    # convention): a real `pip install` into a fresh venv with
    # umask: "0022" succeeds, and the same invalid value below fails
    # with this exact message before ever reaching resolve_pip_binary's
    # own venv-creation step.
    it "fails with real Ansible's exact message for a non-octal umask:" do
      result = PluginSpecHelper.run("pip", {"name" => "six", "umask" => "not_an_octal"})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("umask must be an octal integer")
    end

    it "accepts a valid octal umask: without failing validation" do
      result = PluginSpecHelper.run("pip", {"name" => "six", "umask" => "0022", "executable" => "/bin/false"})

      # /bin/false as executable: means the actual pip invocation always
      # fails - this only confirms umask: validation itself passed (the
      # failure message is about the install, not umask).
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should_not eq("umask must be an octal integer")
    end
  end
end

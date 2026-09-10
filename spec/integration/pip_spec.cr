require "../spec_helper"
require "file_utils"

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

  it "joins a multi-element name: list into comma-separated packages, not the bracketed text" do
    # Real bug found benchmarking claranet.postgresql's own `name: "{{
    # _postgresql_dependencies_pip_packages }}"` - a full-value Jinja
    # substitution of a real multi-item list variable renders as
    # bracketed text (`['psycopg2', 'ipaddress']`), and normalize_name
    # only unwrapped the SINGLE-element case, returning a >1-item list's
    # bracketed text unchanged - #install then comma-split THAT text
    # naively, truncating everything after the first item's own
    # internal comma into a bogus "package" ("['psycopg2'"), and pip
    # errored "Invalid requirement" instead of ever seeing two real
    # package names. state: absent on two not-installed packages only
    # ever calls `pip show` per package (no real install/network call)
    # - safe to run for real, matching this file's own convention.
    result = PluginSpecHelper.run("pip", {
      "name"  => "['definitely-not-a-real-package-xyz', 'also-not-a-real-package-abc']",
      "state" => "absent",
    })

    result["failed"]?.try(&.as_bool).should_not be_true
    result["msg"].as_s.should_not contain("[")
    result["msg"].as_s.should_not contain("Invalid requirement")
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

  # Real bug found benchmarking claranet.postgresql (cold run): a `pip:`
  # task with `virtualenv:` pointing at a not-yet-existing directory
  # creates the venv via `python3 -m venv` - and creating it is itself a
  # change under real Ansible, independent of the package-install step's
  # own outcome. krikri used to report ok/`changed: false` here: the
  # fresh venv bootstraps its own pip, so `pip show <pkg>` succeeded
  # (name: pip is the sharpest repro - the venv's bootstrapped pip IS
  # the requested package), the all_packages_satisfied? short-circuit
  # fired, and the venv creation was never accounted for. These two
  # specs run a REAL `python3 -m venv` (no network, ensurepip is
  # self-contained) under Dir.tempdir, cleaned up after.
  describe "virtualenv:" do
    it "reports changed: true when the task itself created the virtualenv (even if the package is already satisfied by the fresh venv)" do
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      begin
        result = PluginSpecHelper.run("pip", {
          "name"       => "pip",
          "virtualenv" => venv,
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        File.directory?(venv).should be_true
        result["changed"].as_bool.should be_true
      ensure
        FileUtils.rm_rf(venv)
      end
    end

    it "reports changed: false for an already-satisfied package in a pre-existing virtualenv" do
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      begin
        system("python3 -m venv #{venv}").should be_true
        result = PluginSpecHelper.run("pip", {
          "name"       => "pip",
          "virtualenv" => venv,
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        result["changed"].as_bool.should be_false
      ensure
        FileUtils.rm_rf(venv)
      end
    end
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

  describe "pip-module interpreter discovery" do
    # Real bug found benchmarking aloysius-lim.elasticsearch_api (round
    # 91020, Atlantic Rocky 9.6): the host ships only /usr/bin/python3.9 -
    # no unversioned `python3` command at all (common on minimal
    # RHEL-family images) and no `pip3` script - yet real Ansible's pip
    # module installs cleanly there, because it runs pip as
    # `[sys.executable, '-m', 'pip']` with sys.executable being its
    # DISCOVERED interpreter (/usr/bin/python3.9), never a literal
    # `python3`. Krikri's discovery probed the literal name `python3`,
    # got 127, fell through to the pip3 PATH check, also 127, and failed
    # the task with real Ansible's own "Unable to find any of pip3 to
    # use." message on a host where real Ansible succeeded.
    #
    # Simulated with a shim dir REPLACING the whole PATH (apt_key_spec.cr's
    # established shim pattern): python3.9 (symlink to the real
    # interpreter) present, python3 and pip3 absent. state: absent on a
    # not-installed package only ever calls `pip show` (no real
    # install/network call) - safe to run for real, matching this file's
    # own no-real-execution convention.
    it "falls back to a versioned interpreter (python3.9) when the host has no python3 or pip3 binary" do
      python = Process.find_executable("python3") || Process.find_executable("python")
      raise "this spec needs a working python3 -m pip on the spec machine" unless python && python_with_pip?(python)

      shim_dir = File.tempname("/tmp", ".krikri-spec-pip-bin")
      Dir.mkdir(shim_dir)
      File.symlink(File.realpath(python), File.join(shim_dir, "python3.9"))
      File.symlink("/bin/sh", File.join(shim_dir, "sh"))
      old_path = ENV["PATH"]?
      ENV["PATH"] = shim_dir
      begin
        result = PluginSpecHelper.run("pip", {
          "name"  => "definitely-not-a-real-package-xyz",
          "state" => "absent",
        })

        # Got past discovery (not the "Unable to find any of pip3"
        # failure) and the resolved `python3.9 -m pip` command actually
        # ran: pip show answered "not installed" ("Package already
        # absent") rather than the module failing to find any pip at all.
        result["failed"]?.try(&.as_bool).should_not be_true
        result["msg"].as_s.should eq("Package already absent")
      ensure
        ENV["PATH"] = old_path if old_path
        FileUtils.rm_rf(shim_dir)
      end
    end
  end
end

private def python_with_pip?(python : String) : Bool
  Process.run(python, ["-m", "pip", "--version"]).success?
rescue
  false
end

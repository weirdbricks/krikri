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
  it "fails with real Ansible's required_one_of message when neither name nor requirements is given" do
    result = PluginSpecHelper.run("pip", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("one of the following is required: name, requirements")
  end

  it "fails with real Ansible's mutually_exclusive message when both name and requirements are given" do
    result = PluginSpecHelper.run("pip", {
      "name"         => "six",
      "requirements" => "/tmp/requirements.txt",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: name|requirements")
  end

  it "fails with real Ansible's mutually_exclusive message when both executable and virtualenv are given" do
    # Validation runs before anything else (real Ansible checks it in
    # AnsibleModule.__init__), so no venv is created and no pip is
    # discovered - safe to point virtualenv: anywhere.
    result = PluginSpecHelper.run("pip", {
      "name"       => "six",
      "executable" => "pip3",
      "virtualenv" => "/tmp/never-created-venv",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: executable|virtualenv")
    File.directory?("/tmp/never-created-venv").should be_false
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

  it "keeps a version-specifier comma as part of one requirement, not a second bogus package" do
    # Real bug found benchmarking jonaspammer.openssl (round 813196):
    # `name: "cryptography>3,<3.5"` - a single string whose comma is
    # part of one PEP 440 version spec, not a separator between two
    # packages. Naive comma-splitting produced a bogus second "package"
    # starting with `<`, which real pip rejects outright ("Invalid
    # requirement: '<3.5': Expected package name at the start of
    # dependency specifier") - real Ansible's pip.py re-merges such
    # pieces onto the preceding requirement before invoking pip.
    # state: absent on a not-installed package only ever calls `pip
    # show` (no real install/network call) - safe to run for real,
    # matching this file's own no-real-execution convention.
    result = PluginSpecHelper.run("pip", {
      "name"  => "definitely-not-a-real-package-xyz<3.5,>3",
      "state" => "absent",
    })

    result["failed"]?.try(&.as_bool).should_not be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should_not contain("Invalid requirement")
  end

  # The plugin's default virtualenv_command is real Ansible's own
  # argument_spec default ("virtualenv", the classic tool - often NOT
  # installed on minimal hosts, which is real Ansible's behavior too:
  # it would fail with "Failed to find required executable ... in
  # paths:"). These specs pass the space-separated `python3 -m venv`
  # form explicitly, which is itself one of the two virtualenv_command
  # shapes real Ansible documents - and runs a REAL `python3 -m venv`
  # (no network, ensurepip is self-contained) under Dir.tempdir,
  # cleaned up after.
  describe "virtualenv:" do
    it "reports changed: true when the task itself created the virtualenv (even if the package is already satisfied by the fresh venv)" do
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      begin
        result = PluginSpecHelper.run("pip", {
          "name"               => "pip",
          "virtualenv"         => venv,
          "virtualenv_command" => "python3 -m venv",
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        File.directory?(venv).should be_true
        result["changed"].as_bool.should be_true
      ensure
        FileUtils.rm_rf(venv)
      end
    end

    it "fails with real Ansible's message when virtualenv_python is used with a venv-style virtualenv_command" do
      # _is_venv_command's own rule: -p is a virtualenv option, not a
      # venv one, so pairing virtualenv_python: with `... -m venv` is a
      # hard validation error - checked before any creation attempt.
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      begin
        result = PluginSpecHelper.run("pip", {
          "name"               => "pip",
          "virtualenv"         => venv,
          "virtualenv_command" => "python3 -m venv",
          "virtualenv_python"  => "/usr/bin/python3",
        })

        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("virtualenv_python should not be used when using the venv module or pyvenv as virtualenv_command")
        File.directory?(venv).should be_false
      ensure
        FileUtils.rm_rf(venv)
      end
    end

    it "fails when the virtualenv_command binary is missing from PATH" do
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      begin
        result = PluginSpecHelper.run("pip", {
          "name"               => "pip",
          "virtualenv"         => venv,
          "virtualenv_command" => "no-such-venv-tool-xyz",
        })

        result["failed"].as_bool.should be_true
        result["msg"].as_s.should contain("Failed to find required executable no-such-venv-tool-xyz in paths:")
        File.directory?(venv).should be_false
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

  # virtualenv_command / virtualenv_site_packages argument plumbing,
  # verified with a FAKE venv-creation shim (no real virtualenv tool, no
  # network): the shim records its argv to a marker file, fabricates a
  # minimal <venv>/bin/pip stub (exit 0, so the post-creation
  # already-installed check passes without touching any real pip), and
  # mirrors the two --help shapes real Ansible's _get_cmd_options
  # distinguishes (a virtualenv-tool-like help listing --no-site-packages
  # vs. a venv-like one that doesn't). The PATH-replacement shim pattern
  # is pip_spec's own interpreter-discovery spec / apt_key_spec.cr's.
  describe "virtualenv_command + virtualenv_site_packages" do
    it "passes --system-site-packages when virtualenv_site_packages is true" do
      python = Process.find_executable("python3") || Process.find_executable("python")
      raise "this spec needs a python3 on PATH" unless python

      shim_dir = File.tempname("/tmp", ".krikri-spec-pip-bin")
      Dir.mkdir(shim_dir)
      File.symlink("/bin/sh", File.join(shim_dir, "sh"))
      write_venv_shim(shim_dir, "fakevenv", false)
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      old_path = ENV["PATH"]?
      ENV["PATH"] = shim_dir
      begin
        result = PluginSpecHelper.run("pip", {
          "name"                     => "pip",
          "virtualenv"               => venv,
          "virtualenv_command"       => "fakevenv",
          "virtualenv_site_packages" => "true",
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        File.directory?(venv).should be_true
        marker = File.read(File.join(shim_dir, "marker"))
        marker.should contain("--system-site-packages")
        marker.should_not contain("--no-site-packages")
      ensure
        ENV["PATH"] = old_path if old_path
        FileUtils.rm_rf(shim_dir)
        FileUtils.rm_rf(venv)
      end
    end

    it "appends --no-site-packages only when the venv command's --help advertises it" do
      python = Process.find_executable("python3") || Process.find_executable("python")
      raise "this spec needs a python3 on PATH" unless python

      shim_dir = File.tempname("/tmp", ".krikri-spec-pip-bin")
      Dir.mkdir(shim_dir)
      File.symlink("/bin/sh", File.join(shim_dir, "sh"))
      # virtualenv-tool-like: --help lists --no-site-packages (the
      # classic tool's deprecated option); venv-like: it doesn't.
      write_venv_shim(shim_dir, "venvtool", true)
      write_venv_shim(shim_dir, "venvtool_like", false)
      venv = File.join(Dir.tempdir, "krikri-pip-spec-venv-#{Random::Secure.hex(8)}")
      old_path = ENV["PATH"]?
      ENV["PATH"] = shim_dir
      begin
        result = PluginSpecHelper.run("pip", {
          "name"               => "pip",
          "virtualenv"         => venv,
          "virtualenv_command" => "venvtool",
        })
        result["failed"]?.try(&.as_bool).should_not be_true
        File.read(File.join(shim_dir, "marker")).should contain("--no-site-packages")

        FileUtils.rm_rf(venv)
        File.delete(File.join(shim_dir, "marker"))

        result = PluginSpecHelper.run("pip", {
          "name"               => "pip",
          "virtualenv"         => venv,
          "virtualenv_command" => "venvtool_like",
        })
        result["failed"]?.try(&.as_bool).should_not be_true
        File.read(File.join(shim_dir, "marker")).should_not contain("--no-site-packages")
      ensure
        ENV["PATH"] = old_path if old_path
        FileUtils.rm_rf(shim_dir)
        FileUtils.rm_rf(venv)
      end
    end
  end

  # break_system_packages: real Ansible's pip.py sets
  # PIP_BREAK_SYSTEM_PACKAGES=1 in the module's own environment (an env
  # var, not the --break-system-packages flag, so pip < 23.0 works).
  # Verified with a fake pip shim on an absolute executable: path that
  # records that env var plus its argv - `show` exits nonzero for the
  # install-path package (forcing a real pip install invocation) and
  # zero for the uninstall-path one (forcing the uninstall). No real
  # pip, no network.
  describe "break_system_packages" do
    it "sets PIP_BREAK_SYSTEM_PACKAGES=1 on the pip install invocation when true" do
      shim_dir = File.tempname("/tmp", ".krikri-spec-pip-bin")
      Dir.mkdir(shim_dir)
      pip = write_pip_shim(shim_dir)
      begin
        result = PluginSpecHelper.run("pip", {
          "name"                  => "missing-pkg",
          "executable"            => pip,
          "break_system_packages" => "true",
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        marker = File.read(File.join(shim_dir, "marker"))
        marker.should contain("env=1")
        marker.should contain("install")
      ensure
        FileUtils.rm_rf(shim_dir)
      end
    end

    it "leaves PIP_BREAK_SYSTEM_PACKAGES unset when the param is absent" do
      shim_dir = File.tempname("/tmp", ".krikri-spec-pip-bin")
      Dir.mkdir(shim_dir)
      pip = write_pip_shim(shim_dir)
      begin
        result = PluginSpecHelper.run("pip", {
          "name"       => "missing-pkg",
          "executable" => pip,
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        marker = File.read(File.join(shim_dir, "marker"))
        marker.should contain("env=unset")
        marker.should contain("install")
      ensure
        FileUtils.rm_rf(shim_dir)
      end
    end

    it "also sets PIP_BREAK_SYSTEM_PACKAGES=1 on the pip uninstall invocation (PEP 668 blocks that too)" do
      shim_dir = File.tempname("/tmp", ".krikri-spec-pip-bin")
      Dir.mkdir(shim_dir)
      pip = write_pip_shim(shim_dir)
      begin
        result = PluginSpecHelper.run("pip", {
          "name"                  => "present-pkg",
          "state"                 => "absent",
          "executable"            => pip,
          "break_system_packages" => "true",
        })

        result["failed"]?.try(&.as_bool).should_not be_true
        marker = File.read(File.join(shim_dir, "marker"))
        marker.should contain("env=1")
        marker.should contain("uninstall")
      ensure
        FileUtils.rm_rf(shim_dir)
      end
    end
  end
end

private def write_venv_shim(shim_dir : String, name : String, help_lists_no_site_packages : Bool) : String
  shim = File.join(shim_dir, name)
  no_site = help_lists_no_site_packages ? " [--no-site-packages]" : ""
  File.write(shim, <<-SH
    #!/bin/sh
    export PATH=/usr/local/bin:/usr/bin:/bin
    if [ "$1" = "--help" ]; then
      printf 'usage: #{name}#{no_site} ENV_DIR\\n'
      exit 0
    fi
    for last in "$@"; do :; done
    printf '%s\\n' "$@" >> #{File.join(shim_dir, "marker")}
    mkdir -p "$last/bin"
    printf '#!/bin/sh\\nexit 0\\n' > "$last/bin/pip"
    chmod +x "$last/bin/pip"
    SH
  )
  File.chmod(shim, 0o755)
  shim
end

private def write_pip_shim(shim_dir : String) : String
  shim = File.join(shim_dir, "shimmed-pip")
  File.write(shim, <<-SH
    #!/bin/sh
    export PATH=/usr/local/bin:/usr/bin:/bin
    printf 'env=%s args=%s\\n' "${PIP_BREAK_SYSTEM_PACKAGES:-unset}" "$*" >> #{File.join(shim_dir, "marker")}
    case "$1 $2" in
      "show present-pkg") exit 0 ;;
      show*) exit 1 ;;
    esac
    exit 0
    SH
  )
  File.chmod(shim, 0o755)
  shim
end

private def python_with_pip?(python : String) : Bool
  Process.run(python, ["-m", "pip", "--version"]).success?
rescue
  false
end

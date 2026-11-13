require "../minitest_helper"
require "file_utils"

# The package plugin (ansible.builtin.package) dispatches to the host's
# real package manager. check_mode keeps these side-effect-free.
describe "package plugin" do
  it "rejects state: installed on a Debian-family host with apt's own choices error" do
    # `package:` is a dispatcher - state validation happens inside the
    # DELEGATED module, so the accepted choices are host-dependent. On
    # Debian-family hosts ansible-core fails at setup with apt's
    # list and never installs - live-verified against
    # ansible-playbook 2.19.11 (ChristopherDavenport.universal-tomcat,
    # round 984025: this engine used to alias installed→present for
    # every family and reported ok where Ansible errors).
    result = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "installed", "_ansible_check_mode" => "true", "use" => "apt"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, build-dep, fixed, latest, present, got: installed")
  end

  it "keeps installed/removed as valid synonyms on dnf-family backends" do
    # dnf/yum document state choices as absent, installed, latest,
    # present, removed - bertvv.rh-base's own `package: state: installed`
    # tasks (round 60086) succeed on RedHat hosts and must keep working.
    installed = PluginSpecHelper.run("package",
      {"name" => "definitely-not-a-real-package-xyz", "state" => "installed",
       "_ansible_check_mode" => "true", "use" => "dnf"})
    installed["msg"].as_s.wont_include("must be one of")

    removed = PluginSpecHelper.run("package",
      {"name" => "definitely-not-a-real-package-xyz", "state" => "removed",
       "_ansible_check_mode" => "true", "use" => "dnf"})
    removed["msg"].as_s.wont_include("must be one of")
  end

  it "fails a use: naming a backend this engine doesn't ship, with Ansible's message" do
    # Ansible's package action plugin checks its controller-side
    # module library and fails before anything runs: live-verified
    # (`ansible localhost -m package -a "name=x state=present
    # use=nonexistentmgr"` => 'Could not find a matching action for the
    # "nonexistentmgr" package manager.'). The validation also precedes
    # module execution, so it fires even without a `name:`.
    result = PluginSpecHelper.run("package",
      {"use" => "homebrew"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Could not find a matching action for the \"homebrew\" package manager.")
  end

  it "use: overrides auto-detection unconditionally (dnf backend honored on an apt host)" do
    # Ansible dispatches straight to the `use:`-named module - NOT
    # a fallback: live-verified `use: dnf` on this apt host still ran
    # the dnf module (which then failed on-target for lack of dnf).
    # Here the override picks the dnf backend, whose rpm-based
    # installed-check can't see the dpkg-installed package and whose
    # repo probes come up empty on this host, so the dnf module's own
    # unresolvable-spec failure shape comes back - not the apt
    # backend's already-installed no-op.
    result = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "_ansible_check_mode" => "true", "use" => "dnf"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to install some of the specified packages")
    result["failures"].as_a.map(&.as_s).must_equal(["No package bash available."])
  end

  it "use: apt selects the apt backend explicitly" do
    result = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "_ansible_check_mode" => "true", "use" => "apt"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    # Ansible 2.19.11's unchanged-present exit carries NO msg - just the
    # cache pair (live-verified; see key_order_sweep7_test.cr).
    result["cache_updated"].as_bool.must_equal(false)
    result["msg"]?.must_be_nil
  end

  it "the ansible_package_use variable overrides auto-detection but loses to use:" do
    # Ansible 2.17+: the ansible_package_use variable overrides
    # auto-detection, while an explicit `use:` option still takes
    # precedence over the variable.
    with_var = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "_ansible_check_mode" => "true"},
      {"ansible_package_use" => "dnf"})
    # The dnf backend ran (issue #753 shape: on this rpm/dnf-less host
    # its repo probes come up empty and the dnf module's own
    # unresolvable-spec failure comes back) - not the apt backend the
    # auto-detection would have picked.
    with_var["failed"].as_bool.must_equal(true)
    with_var["msg"].as_s.must_equal("Failed to install some of the specified packages")

    with_both = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "_ansible_check_mode" => "true", "use" => "apt"},
      {"ansible_package_use" => "dnf"})
    with_both["changed"].as_bool.must_equal(false)
    with_both["cache_updated"].as_bool.must_equal(false)
  end

  it "treats a missing name as a no-op, not a hard error (round 83221)" do
    # adfinis-sygroup.apache's `package: {state: present}` task has no
    # `name:` key at all. Ansible's apt backend never hard-fails a
    # missing name (its required_one_of gate is defeated by the
    # upgrade/autoremove defaults) - it exits changed=false. Verified
    # live: `ansible localhost -m package -a "state=present"` => SUCCESS,
    # changed: false.
    result = PluginSpecHelper.run("package",
      {"state" => "present"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["msg"].as_s.wont_include("Missing required parameter")
  end

  it "treats an empty-string name as a no-op (round 83246)" do
    # `name: '{{ var }}'` with the var an empty list templates to "[]" or
    # an empty string; Ansible's apt backend exits changed=false on
    # an empty package list for both present and absent. This engine
    # used to run `apt-get remove` on the empty token and report
    # "Package  removed" (double space) as changed on every run.
    ["", "[]"].each do |empty_name|
      result = PluginSpecHelper.run("package",
        {"name" => empty_name, "state" => "absent"})

      result["changed"].as_bool.must_equal(false)
      # Ansible 2.19.11's absent-nochange exit is a bare exit_json(changed=
      # False) with no msg at all (live-verified; see
      # key_order_sweep7_test.cr) - so the msg key may be absent entirely.
      (result["msg"]? || JSON::Any.new("")).as_s.wont_include("removed")
    end
  end
end

# Issue #732 (Rocky 9, moshloop.java): `package: name: curl` on a host
# with curl-minimal installed must still reach the install batch, like
# dnf.cr's own package_installed? since issue #280 - curl-minimal
# Provides: the "curl" capability, so the --whatprovides fallback used
# to classify curl as already installed and skip it, while real ansible
# hands the name to python-dnf, resolves it to the repo package curl
# and fails with dnf's own Depsolve Error (curl conflicts with
# curl-minimal). dnf/rpm are not on the spec host, so the same fake
# rpm/dnf pair dnf_param_coverage_test.cr uses builds the Rocky
# resolution table by hand: plain `rpm -q` never matches, the
# whatprovides lookup matches KRIKRI_FAKE_RPM_PROVIDES, the
# availability probe matches KRIKRI_FAKE_DNF_AVAILABLE.
private PACKAGE732_RPM = <<-'SH'
#!/bin/sh
[ "$2" = "--whatprovides" ] || exit 1
for n in ${KRIKRI_FAKE_RPM_PROVIDES:-}; do
  [ "$3" = "$n" ] && exit 0
done
exit 1
SH

private PACKAGE732_DNF = <<-'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${KRIKRI_FAKE_DNF_LOG:?}"
case "$2/$3" in
  "list/--available")
    # Every requested spec rides in ONE invocation (issue #904), so each
    # carried name answers with a row like real dnf prints and the
    # invocation exits 0 as soon as any of them matched.
    found=1
    for n in "$@"; do
      for a in ${KRIKRI_FAKE_DNF_AVAILABLE:-}; do
        if [ "$n" = "$a" ]; then
          printf '%s.x86_64  1.0-1.el9  fake\n' "$n"
          found=0
          break
        fi
      done
    done
    exit $found
    ;;
esac
echo "Installed:"
echo "  fake-pkg"
exit 0
SH

private def with_package732_pkg_managers(provides : Array(String) = [] of String, available : Array(String) = [] of String, &)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    bin_dir = File.tempname("krikri-package732-fakes")
    Dir.mkdir_p(bin_dir)
    rpm = File.join(bin_dir, "rpm")
    File.write(rpm, PACKAGE732_RPM)
    File.chmod(rpm, 0o755)
    dnf = File.join(bin_dir, "dnf")
    File.write(dnf, PACKAGE732_DNF)
    File.chmod(dnf, 0o755)

    log = File.tempname("krikri-package732-dnf-log")
    previous_path = ENV["PATH"]?
    previous_log = ENV["KRIKRI_FAKE_DNF_LOG"]?
    previous_provides = ENV["KRIKRI_FAKE_RPM_PROVIDES"]?
    previous_available = ENV["KRIKRI_FAKE_DNF_AVAILABLE"]?
    ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
    ENV["KRIKRI_FAKE_DNF_LOG"] = log
    ENV["KRIKRI_FAKE_RPM_PROVIDES"] = provides.join(" ")
    ENV["KRIKRI_FAKE_DNF_AVAILABLE"] = available.join(" ")
    begin
      yield log
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_log ? (ENV["KRIKRI_FAKE_DNF_LOG"] = previous_log) : ENV.delete("KRIKRI_FAKE_DNF_LOG")
      previous_provides ? (ENV["KRIKRI_FAKE_RPM_PROVIDES"] = previous_provides) : ENV.delete("KRIKRI_FAKE_RPM_PROVIDES")
      previous_available ? (ENV["KRIKRI_FAKE_DNF_AVAILABLE"] = previous_available) : ENV.delete("KRIKRI_FAKE_DNF_AVAILABLE")
      FileUtils.rm_r(bin_dir)
      File.delete(log) if File.exists?(log)
    end
  end
end

describe "package plugin - same-name repo package vs a Provides: match (issue 732)" do
  it "sends an available-name package to the install batch despite a Provides: match" do
    with_package732_pkg_managers(provides: ["curl"], available: ["curl"]) do |log|
      result = PluginSpecHelper.run("package", {"name" => "curl", "state" => "present", "use" => "dnf"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read_lines(log).must_equal([
        "-q list --available curl",
        "install -y --setopt=localpkg_gpgcheck=1 curl",
      ])
    end
  end

  it "keeps a purely virtual name on the Provides: fallback (no repo row)" do
    with_package732_pkg_managers(provides: ["php-json"], available: [] of String) do |log|
      result = PluginSpecHelper.run("package", {"name" => "php-json", "state" => "present", "use" => "dnf"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Package php-json already installed")
      # Issue #1019: the satisfied no-op still runs dnf's own metadata
      # load before it can know the transaction is empty (ansible's
      # fill_sack() happens before any resolution), so the install probe
      # follows the classification query.
      File.read_lines(log).must_equal([
        "-q list --available php-json",
        "install -y --setopt=localpkg_gpgcheck=1 --nobest --setopt=tsflags=test php-json",
      ])
    end
  end
end

# Issue #1217 (daixijun.toolkit): the async `package:` job's until:/
# retries: poll loop printed extra "FAILED - RETRYING" lines and a higher
# attempts value than real ansible. The job spent those extra seconds
# asking the repos a question only this engine's own CHECK-MODE branches
# read: ansible hands the whole name list to one in-process depsolve, so
# the real install already decides a spec's fate, while each per-spec
# `dnf -q provides` here is a full dnf CLI startup (~0.6-1.3s) and every
# one of them pushed the 5s poll loop nearer another boundary.
describe "package plugin - repo availability probes are check-mode only (issue 1217)" do
  it "installs an unresolvable name without a per-spec repo probe" do
    with_package732_pkg_managers(available: [] of String) do |log|
      result = PluginSpecHelper.run("package", {"name" => "definitely-not-in-any-repo", "state" => "present", "use" => "dnf"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read_lines(log).must_equal([
        "-q list --available definitely-not-in-any-repo",
        "install -y --setopt=localpkg_gpgcheck=1 definitely-not-in-any-repo",
      ])
    end
  end

  it "still asks the repos about an unresolvable name under check mode" do
    with_package732_pkg_managers(available: [] of String) do |log|
      result = PluginSpecHelper.run("package", {"name" => "definitely-not-in-any-repo", "state" => "present",
                                                "_ansible_check_mode" => "true", "use" => "dnf"})
      result["failed"].as_bool.must_equal(true)
      File.read_lines(log).must_include("-q provides definitely-not-in-any-repo")
    end
  end
end

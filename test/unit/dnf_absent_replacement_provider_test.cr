require "../minitest_helper"
require "file_utils"
require "json"

# Issue #1794 (shomatan.cron, Rocky 9): `yum: name=cronie-anacron
# state=absent` read changed for real ansible but also ERASED cronie
# (and stopped crond), so the role's next two tasks - installing
# cronie-noanacron and starting/enabling crond - reported changed where
# ansible said ok. Ansible's absent goal fill_sack()s the available
# repos and resolves with allow_erasing forced on (dnf.py
# _ensure_impl), so its solver keeps cronie installed by adding the
# alternative provider cronie-noanacron for cronie's `dailyjobs`
# requirement. The `dnf remove` CLI deliberately disables the available
# repos there ("disable all available repos to delete whole dependency
# tree instead of replacing removable package with available
# packages", dnf/cli/commands/remove.py) and erases the dependent
# instead. This engine now replays ansible's resolution through the
# target's python-dnf (DnfTransactionProbe, already used for failed
# installs) and installs the replacement providers it names before the
# bare removal runs.
#
# dnf/rpm are not on the spec host; everything runs against shimmed
# binaries on PATH through the plugin's _environment (same method as
# the other dnf specs) - no process-wide ENV mutation, so no serial!.
private def with_yum1794_shims(dep_broken : String, probe_json : String, &)
  bin_dir = File.join(Dir.tempdir, "krikri-yum1794-#{Random.rand(1_000_000)}")
  log = File.join(bin_dir, "calls.log")
  FileUtils.mkdir_p(bin_dir)

  rpm_shim = <<-'SH'
    #!/bin/sh
    printf 'rpm %s\n' "$*" >> "${KRIKRI_CALL_LOG:?}"
    if [ "$1" = "-e" ]; then
      if [ -n "${KRIKRI_RPM_DEP_BROKEN:-}" ]; then
        printf 'error: Failed dependencies:\n\t%s\n' "$KRIKRI_RPM_DEP_BROKEN" >&2
        exit 1
      fi
      exit 0
    fi
    if [ "$2" = "--whatprovides" ]; then
      exit 1
    fi
    qarg="$4"
    [ -n "$qarg" ] || qarg="$2"
    case "$qarg" in
      cronie) printf 'cronie-1.5.7-16.el9.x86_64'; exit 0 ;;
      cronie-anacron) printf 'cronie-anacron-1.5.7-16.el9.x86_64'; exit 0 ;;
      cronie-noanacron) printf 'cronie-noanacron-1.5.7-16.el9.x86_64'; exit 0 ;;
    esac
    exit 1
    SH

  pkg_shim = <<-'SH'
    #!/bin/sh
    printf '%s %s\n' "$(basename "$0")" "$*" >> "${KRIKRI_CALL_LOG:?}"
    case "$1" in
      makecache)
        echo "Metadata cache created"
        exit 0
        ;;
      install)
        echo "Installed:"
        echo "  cronie-noanacron-1.5.7-16.el9.x86_64"
        exit 0
        ;;
      remove)
        echo "Removed:"
        echo "  cronie-anacron-1.5.7-16.el9.x86_64"
        exit 0
        ;;
    esac
    exit 0
    SH

  python_shim = <<-'SH'
    #!/bin/sh
    printf 'python3\n' >> "${KRIKRI_CALL_LOG:?}"
    printf '%s\n' "${KRIKRI_PROBE_JSON:?}"
    SH

  File.write(File.join(bin_dir, "rpm"), rpm_shim)
  File.write(File.join(bin_dir, "dnf"), pkg_shim)
  File.write(File.join(bin_dir, "yum"), pkg_shim)
  File.write(File.join(bin_dir, "python3"), python_shim)
  {"rpm", "dnf", "yum", "python3"}.each { |bin| File.chmod(File.join(bin_dir, bin), 0o755) }

  env = {
    "PATH"                  => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_CALL_LOG"       => log,
    "KRIKRI_RPM_DEP_BROKEN" => dep_broken,
    "KRIKRI_PROBE_JSON"     => probe_json,
  }.to_json
  yield env
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

private def yum1794_log(env : String) : Array(String)
  parsed = JSON.parse(env).as_h
  File.read(parsed["KRIKRI_CALL_LOG"].as_s).lines.map(&.strip).reject(&.empty?)
end

REPLACEMENT_PLAN = [
  "Installed: cronie-noanacron-1.5.7-16.el9.x86_64",
  "Removed: cronie-anacron-1.5.7-16.el9.x86_64",
]

describe "yum/dnf absent keeps dependents ansible's solver keeps (issue 1794)" do
  it "installs the resolved replacement provider before the bare removal" do
    with_yum1794_shims("dailyjobs is needed by (installed) cronie-1.5.7-16.el9.x86_64",
      {"results" => REPLACEMENT_PLAN}.to_json) do |env|
      result = PluginSpecHelper.run("yum", {
        "name"         => "cronie-anacron",
        "state"        => "absent",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("")
      result["results"].as_a.map(&.as_s).must_equal(REPLACEMENT_PLAN)
      result["rc"].as_i.must_equal(0)

      calls = yum1794_log(env)
      install = calls.index { |line| line.starts_with?("yum install") || line.starts_with?("dnf install") } || -1
      remove = calls.index { |line| line.starts_with?("yum remove") || line.starts_with?("dnf remove") } || -1
      (install >= 0).must_equal(true)
      (remove >= 0).must_equal(true)
      (install < remove).must_equal(true)
      calls[install].includes?("cronie-noanacron-1.5.7-16.el9.x86_64").must_equal(true)
      calls[install].includes?("--allowerasing").must_equal(true)
      calls[remove].includes?("cronie-anacron").must_equal(true)
    end
  end

  it "runs only the removal when the solver adds no provider" do
    cascade = [
      "Removed: cronie-1.5.7-16.el9.x86_64",
      "Removed: cronie-anacron-1.5.7-16.el9.x86_64",
    ]
    with_yum1794_shims("dailyjobs is needed by (installed) cronie-1.5.7-16.el9.x86_64",
      {"results" => cascade}.to_json) do |env|
      result = PluginSpecHelper.run("yum", {
        "name"         => "cronie-anacron",
        "state"        => "absent",
        "_environment" => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["results"].as_a.map(&.as_s).must_equal(cascade)
      calls = yum1794_log(env)
      calls.any? { |line| line.includes?(" install ") }.must_equal(false)
      calls.any? { |line| line.includes?(" remove ") }.must_equal(true)
    end
  end

  it "skips the python-dnf replay when rpm reports nothing stranded" do
    with_yum1794_shims("", {"results" => REPLACEMENT_PLAN}.to_json) do |env|
      result = PluginSpecHelper.run("yum", {
        "name"         => "cronie-anacron",
        "state"        => "absent",
        "_environment" => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["results"].as_a.map(&.as_s).must_equal(["Removed: cronie-anacron-1.5.7-16.el9.x86_64"])
      calls = yum1794_log(env)
      calls.includes?("python3").must_equal(false)
      calls.any? { |line| line.includes?(" install ") }.must_equal(false)
    end
  end

  it "check mode reports the resolved plan without running any transaction" do
    with_yum1794_shims("dailyjobs is needed by (installed) cronie-1.5.7-16.el9.x86_64",
      {"results" => REPLACEMENT_PLAN}.to_json) do |env|
      result = PluginSpecHelper.run("yum", {
        "name"                => "cronie-anacron",
        "state"               => "absent",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(REPLACEMENT_PLAN)
      calls = yum1794_log(env)
      calls.any? { |line| line.includes?(" install ") }.must_equal(false)
      calls.any? { |line| line.includes?(" remove ") }.must_equal(false)
    end
  end
end

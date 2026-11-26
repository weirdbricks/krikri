require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/flatpak_remote.cr, the native port of
# community.general.flatpak_remote added for issue #1774
# (alvistack.firefox).
#
# Before the port the task was dropped as an unimplemented plugin -
# krikri skipped every loop item and ran on (rc=4) where real ansible ran
# the module and failed it with the module's own "Executable 'flatpak'
# was not found on the system." (failed=1, rc=2). The module queries run
# in check mode too, so both engines have to reach the binary probe.
#
# Shapes pinned here (all live-verified against real
# community.general.flatpak_remote with ansible-core 2.21.6):
# - a missing binary is a fail_json with the module's wording (NOT
#   get_bin_path's "Failed to find required executable"), and the
#   `executable:` value is echoed verbatim;
# - remote-add/remote-delete/remote-modify are check-mode noops, while
#   remote-list always runs;
# - the exit_json dict keeps command/rc/stdout/stderr from the LAST
#   command, queries included (changed, command, rc, stdout, stderr);
# - a nonzero `flatpak` exit under run_command(check_rc=True) fails with
#   stderr.rstrip as msg plus the shell-quoted cmd/rc/stdout/stderr;
# - argspec order: unsupported params, bool conversion, required, choices.
describe "flatpak_remote plugin" do
  # A fake `flatpak` the tests steer through marker files: `state/` holds
  # the remote-list output and records every mutating command that ran.
  FLATPAK_SHIM = <<-SHIM
    #!/bin/bash
    dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    state="$dir/state"
    mkdir -p "$state"
    if [ "$1" = "--version" ]; then echo "Flatpak 1.16.6"; exit 0; fi
    if [ -f "$state/fail" ]; then cat "$state/fail" >&2; exit 1; fi
    cmd="$1"; shift
    case "$cmd" in
      remote-list) cat "$state/remote-list.txt" 2>/dev/null; exit 0 ;;
      remote-add|remote-delete|remote-modify) echo "$cmd $*" >> "$state/ran.txt"; exit 0 ;;
    esac
    exit 0
    SHIM

  private def with_flatpak_shim(&)
    dir = PluginSpecHelper.tmp_path("flatpak-remote-shim")
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    File.write(File.join(bin_dir, "flatpak"), FLATPAK_SHIM)
    File.chmod(File.join(bin_dir, "flatpak"), 0o755)
    yield dir, bin_dir
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  # A PATH the module's get_bin_path probe searches: the shim dir first,
  # then the system dirs the shim itself needs for cat/dirname.
  private def shim_path(bin_dir : String) : String
    "#{bin_dir}:/usr/bin:/bin"
  end

  it "fails a missing flatpak with the module's own wording" do
    empty = PluginSpecHelper.tmp_path("flatpak-remote-no-path")
    FileUtils.mkdir_p(empty)
    begin
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"  => "flathub",
        "state" => "present",
      }, env: {"PATH" => empty})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Executable 'flatpak' was not found on the system.")
    ensure
      FileUtils.rm_rf(empty)
    end
  end

  it "echoes an explicit executable path in the missing-binary failure" do
    result = PluginSpecHelper.run("flatpak_remote", {
      "name"       => "flathub",
      "state"      => "present",
      "executable" => "/nonexistent/flatpak",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Executable '/nonexistent/flatpak' was not found on the system.")
  end

  it "adds a missing remote in check mode without running the mutating command" do
    with_flatpak_shim do |dir, bin_dir|
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"                => "flathub",
        "flatpakrepo_url"     => "https://dl.flathub.org/repo/flathub.flatpakrepo",
        "state"               => "present",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      # enabled defaults to true and a remote that does not exist is not
      # enabled, so the LAST recorded command is the enable noop.
      result["command"].as_s.must_equal("#{bin_dir}/flatpak remote-modify --enable --system flathub")
      result["rc"].as_i.must_equal(0)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
      File.exists?(File.join(dir, "state", "ran.txt")).must_equal(false)
    end
  end

  it "reports an existing enabled remote unchanged" do
    with_flatpak_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", "remote-list.txt"), "flathub\thttps://dl.flathub.org/repo/\n")
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"  => "flathub",
        "state" => "present",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(false)
      result["command"].as_s.must_equal("#{bin_dir}/flatpak remote-list --show-disabled --system")
      File.exists?(File.join(dir, "state", "ran.txt")).must_equal(false)
    end
  end

  it "enables a disabled remote in check mode" do
    with_flatpak_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", "remote-list.txt"), "flathub\tdisabled\n")
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"                => "flathub",
        "state"               => "present",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal("#{bin_dir}/flatpak remote-modify --enable --system flathub")
    end
  end

  it "disables an existing enabled remote when enabled is false" do
    with_flatpak_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", "remote-list.txt"), "flathub\thttps://dl.flathub.org/repo/\n")
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"                => "flathub",
        "state"               => "present",
        "enabled"             => "false",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal("#{bin_dir}/flatpak remote-modify --disable --system flathub")
    end
  end

  it "removes an existing remote in check mode" do
    with_flatpak_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", "remote-list.txt"), "flathub\thttps://dl.flathub.org/repo/\n")
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"                => "flathub",
        "state"               => "absent",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal("#{bin_dir}/flatpak remote-delete --system --force flathub")
      File.exists?(File.join(dir, "state", "ran.txt")).must_equal(false)
    end
  end

  it "fails a nonzero flatpak exit with run_command's check_rc shape" do
    with_flatpak_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", "fail"), "boom: remote-list failed\n")
      result = PluginSpecHelper.run("flatpak_remote", {
        "name"  => "flathub",
        "state" => "present",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("boom: remote-list failed")
      result["rc"].as_i.must_equal(1)
      result["cmd"].as_s.must_equal("#{bin_dir}/flatpak remote-list --show-disabled --system")
      result["stderr"].as_s.must_equal("boom: remote-list failed\n")
      result["stdout"].as_s.must_equal("")
    end
  end

  it "fails missing name before an out-of-spec state" do
    result = PluginSpecHelper.run("flatpak_remote", {"state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails out-of-spec method and state with the argspec wording" do
    method = PluginSpecHelper.run("flatpak_remote", {"name" => "flathub", "method" => "bogus"})
    method["msg"].as_s.must_equal("value of method must be one of: user, system, got: bogus")

    state = PluginSpecHelper.run("flatpak_remote", {"name" => "flathub", "state" => "bogus"})
    state["msg"].as_s.must_equal("value of state must be one of: absent, present, got: bogus")
  end

  it "fails missing name ahead of a typo'd parameter and its other errors" do
    typo = PluginSpecHelper.run("flatpak_remote", {"nmae" => "jvwrzl"})
    typo["failed"].as_bool.must_equal(true)
    typo["msg"].as_s.must_equal("missing required arguments: name")

    everything = PluginSpecHelper.run(
      "flatpak_remote", {"nmae" => "jvwrzl", "enabled" => "bogus", "state" => "bogus"})
    everything["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails an unsupported parameter once the other arguments validate" do
    result = PluginSpecHelper.run("flatpak_remote", {"name" => "flathub", "nope" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (community.general.flatpak_remote) module: nope. " \
      "Supported parameters include: enabled, executable, flatpakrepo_url, method, name, state."
    )
  end

  it "fails a non-boolean enabled with the bool-param wording" do
    result = PluginSpecHelper.run("flatpak_remote", {"name" => "flathub", "enabled" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?(
      "argument 'enabled' is of type str and we were unable to convert to bool: " \
      "The value 'bogus' is not a valid boolean."
    ).must_equal(true)
  end
end

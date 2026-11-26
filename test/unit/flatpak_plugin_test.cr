require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/flatpak.cr, the native port of
# community.general.flatpak added for issue #1774 (alvistack.firefox).
#
# Before the port the "flatpak install" task was dropped as an
# unimplemented plugin (the same role's flatpak_remote task above it is
# the diverging one); real ansible runs the module in check mode too, so
# a host with no flatpak binary fails with the module's own wording.
#
# Shapes pinned here (all live-verified against real
# community.general.flatpak with ansible-core 2.21.6):
# - a missing binary is a fail_json with the module's wording, echoing
#   the `executable:` value;
# - install/update/uninstall are check-mode noops, `flatpak list` always
#   runs;
# - flatpak < 1.1.3 uses -y, newer --noninteractive, decided by the
#   `flatpak --version` probe;
# - a .flatpakref URL resolves to its last path segment minus the
#   extension for the installed-name comparison;
# - the exit_json dict keeps command/rc/stdout/stderr from the LAST
#   command, queries included.
describe "flatpak plugin" do
  # A fake `flatpak` steered by marker files: state/list.txt is what
  # `flatpak list` prints, state/fail_columns makes the
  # --columns=application option fail like flatpak < 1.2, and state/ran.txt
  # records every mutating command that actually ran.
  FLATPAK_SHIM = <<-SHIM
    #!/bin/bash
    dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    state="$dir/state"
    mkdir -p "$state"
    if [ "$1" = "--version" ]; then cat "$state/version.txt" 2>/dev/null || echo "Flatpak 1.16.6"; exit 0; fi
    if [ -f "$state/fail" ]; then cat "$state/fail" >&2; exit 1; fi
    cmd="$1"; shift
    case "$cmd" in
      list)
        case " $* " in
          *" --columns=application "*)
            if [ -f "$state/fail_columns" ]; then
              echo "Unknown option --columns=application" >&2
              exit 1
            fi
            ;;
        esac
        cat "$state/list.txt" 2>/dev/null
        exit 0 ;;
      install|update|uninstall) echo "$cmd $*" >> "$state/ran.txt"; exit 0 ;;
    esac
    exit 0
    SHIM

  private def with_flatpak_shim(&)
    dir = PluginSpecHelper.tmp_path("flatpak-shim")
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    File.write(File.join(bin_dir, "flatpak"), FLATPAK_SHIM)
    File.chmod(File.join(bin_dir, "flatpak"), 0o755)
    yield dir, bin_dir
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  private def shim_path(bin_dir : String) : String
    "#{bin_dir}:/usr/bin:/bin"
  end

  private def write_state(dir : String, name : String, content : String) : Nil
    FileUtils.mkdir_p(File.join(dir, "state"))
    File.write(File.join(dir, "state", name), content)
  end

  it "fails a missing flatpak with the module's own wording" do
    empty = PluginSpecHelper.tmp_path("flatpak-no-path")
    FileUtils.mkdir_p(empty)
    begin
      result = PluginSpecHelper.run("flatpak", {
        "name"  => "org.mozilla.firefox",
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
    result = PluginSpecHelper.run("flatpak", {
      "name"       => "org.mozilla.firefox",
      "executable" => "/nonexistent/flatpak",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Executable '/nonexistent/flatpak' was not found on the system.")
  end

  it "would install a missing flatpak in check mode without running the command" do
    with_flatpak_shim do |dir, bin_dir|
      result = PluginSpecHelper.run("flatpak", {
        "name"                => "org.mozilla.firefox",
        "state"               => "present",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak install --system --noninteractive flathub org.mozilla.firefox")
      result["rc"].as_i.must_equal(0)
      File.exists?(File.join(dir, "state", "ran.txt")).must_equal(false)
    end
  end

  it "reports an already-installed flatpak unchanged" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"  => "org.mozilla.firefox",
        "state" => "present",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(false)
      result["command"].as_s.must_equal("#{bin_dir}/flatpak list --system")
      File.exists?(File.join(dir, "state", "ran.txt")).must_equal(false)
    end
  end

  it "resolves a .flatpakref URL to its app id for the installed check" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"  => "https://dl.flathub.org/repo/appstream/org.mozilla.firefox.flatpakref",
        "state" => "present",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(false)
    end
  end

  it "would remove an installed flatpak in check mode" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"                => "org.mozilla.firefox",
        "state"               => "absent",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak uninstall --noninteractive --system org.mozilla.firefox")
      File.exists?(File.join(dir, "state", "ran.txt")).must_equal(false)
    end
  end

  it "would update an installed flatpak to latest in check mode" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"                => "org.mozilla.firefox",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak update --system --noninteractive org.mozilla.firefox")
    end
  end

  it "matches the installed name through the pre-1.2 column fallback" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox org.mozilla.firefox 128.0 stable system\n")
      write_state(dir, "fail_columns", "")
      result = PluginSpecHelper.run("flatpak", {
        "name"                => "org.mozilla.firefox",
        "state"               => "absent",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak uninstall --noninteractive --system org.mozilla.firefox")
    end
  end

  it "installs only the names missing from a comma-separated list" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"                => "org.mozilla.firefox,org.gnome.gedit",
        "state"               => "present",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak install --system --noninteractive flathub org.gnome.gedit")
    end
  end

  it "accepts a YAML list as the JSON the wire serializes it to" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "list.txt", "org.mozilla.firefox\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"                => ["org.mozilla.firefox", "org.gnome.gedit"].to_json,
        "state"               => "present",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak install --system --noninteractive flathub org.gnome.gedit")
    end
  end

  it "uses -y for a flatpak older than 1.1.3" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "version.txt", "Flatpak 1.0.9\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"                => "org.mozilla.firefox",
        "state"               => "present",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["command"].as_s.must_equal(
        "#{bin_dir}/flatpak install --system -y flathub org.mozilla.firefox")
    end
  end

  it "fails a nonzero flatpak exit with run_command's check_rc shape" do
    with_flatpak_shim do |dir, bin_dir|
      write_state(dir, "fail", "boom: list failed\n")
      result = PluginSpecHelper.run("flatpak", {
        "name"  => "org.mozilla.firefox",
        "state" => "present",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("boom: list failed")
      result["rc"].as_i.must_equal(1)
      result["cmd"].as_s.must_equal("#{bin_dir}/flatpak list --system")
    end
  end

  it "fails missing name and out-of-spec choices with the argspec wording" do
    missing = PluginSpecHelper.run("flatpak", {"state" => "present"})
    missing["msg"].as_s.must_equal("missing required arguments: name")

    method = PluginSpecHelper.run("flatpak", {"name" => "app", "method" => "bogus"})
    method["msg"].as_s.must_equal("value of method must be one of: user, system, got: bogus")

    state = PluginSpecHelper.run("flatpak", {"name" => "app", "state" => "bogus"})
    state["msg"].as_s.must_equal("value of state must be one of: absent, present, latest, got: bogus")
  end

  it "fails missing name ahead of an unsupported parameter" do
    result = PluginSpecHelper.run("flatpak", {"nope" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails an unsupported parameter once the other arguments validate" do
    result = PluginSpecHelper.run("flatpak", {"name" => "app", "nope" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (community.general.flatpak) module: nope. " \
      "Supported parameters include: executable, method, name, no_dependencies, remote, state."
    )
  end
end

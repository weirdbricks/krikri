require "../minitest_helper"
require "file_utils"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Regression spec for plugins/homebrew_cask.cr, pinned against real
# community.general.homebrew_cask on this host (ansible-core 2.21.6 /
# community.general 11.x, both the failure shapes and every state flow
# live-compared): ansible-core's builtin runtime redirects the
# ansible.builtin.homebrew_cask spelling to community.general and RUNS it,
# so the old graceful unavailable-module skip diverged on
# rooland-provisioning.atom-editor (issue #1587) - real fails the task with
# get_bin_path's wording and stops the play (rc=2) where krikri skipped
# (rc=4).
#
# Shape facts pinned here (all live-verified or source-derived from the
# module):
# - a missing brew fails with get_bin_path's exact wording; the reported
#   path list is the `path:` value's EXISTING dirs first, then $PATH, then
#   the existing sbin dirs basic.py appends - non-existent opt_dirs are
#   filtered out (os.path.exists gate);
# - `state:` outside the argument spec's choices fails with the argspec
#   wording BEFORE the brew lookup (module setup precedes main());
# - an invalid `path:` fails with the path setter's HomebrewCaskException
#   escaping main() - the uncaught-exception crash shape whose result msg
#   carries the whole "Task failed: Module failed: ..." chain, unlike a
#   fail_json result whose msg stays bare;
# - an invalid cask name sets failed+message and raises - the BARE
#   fail_json shape (no "Plugin execution failed:" prefix);
# - with brew resolvable, state=present installs what `brew list --cask`
#   says is missing, reports an already-installed cask unchanged, and
#   summarizes a multi-cask result as "Changed: N, Unchanged: M"; check
#   mode reports "would be" and never runs the mutating command;
# - state=absent only uninstalls installed casks;
# - upgrade_all in check mode reports "Casks would be upgraded.".
describe "homebrew_cask plugin" do
  # A fake `brew` whose behavior the tests control through marker files:
  # a cask is "installed" when state/<cask> exists, "outdated" when
  # state/.outdated-<cask> exists. `--version` reports 4.1.2 so the module
  # uses the post-2.6.0 `--cask` flag spelling.
  BREW_SHIM = <<-SHIM
    #!/bin/bash
    dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    state="$dir/state"
    mkdir -p "$state"
    cmd="$1"; shift
    case "$cmd" in
      --version) echo "Homebrew 4.1.2"; exit 0 ;;
    esac
    [ "$1" = "--cask" ] && shift
    case "$cmd" in
      list)
        [ -f "$state/$1" ] && exit 0
        exit 1 ;;
      outdated)
        [ "$1" = "--greedy" ] && shift
        [ -f "$state/.outdated-$1" ] && echo "$1"
        exit 0 ;;
      install)
        for n in "$@"; do case "$n" in --*) continue ;; esac; touch "$state/$n"; done
        exit 0 ;;
      uninstall)
        for n in "$@"; do case "$n" in --*) continue ;; esac; rm -f "$state/$n"; done
        exit 0 ;;
      upgrade)
        for n in "$@"; do
          case "$n" in --*) continue ;; esac
          touch "$state/$n"
          rm -f "$state/.outdated-$n"
        done
        exit 0 ;;
      *) exit 0 ;;
    esac
    SHIM

  # A successful module result carries no `failed` key at all (the module
  # protocol only adds it on a fail_json exit) - helper because JSON::Any#raw
  # types as a union.
  private def has_failed_key?(result : JSON::Any) : Bool
    (result.as_h?.try(&.has_key?("failed")) || false)
  end

  private def with_brew_shim(&)
    dir = PluginSpecHelper.tmp_path("homebrew-cask-shim")
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    File.write(File.join(bin_dir, "brew"), BREW_SHIM)
    File.chmod(File.join(bin_dir, "brew"), 0o755)
    yield dir, bin_dir
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  it "fails a missing brew with get_bin_path's wording, existing opt_dirs first" do
    dir = PluginSpecHelper.tmp_path("homebrew-cask-missing")
    begin
      real_dir = File.join(dir, "real")
      FileUtils.mkdir_p(real_dir)
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"  => "atom",
        "path"  => "#{dir}/nope:#{real_dir}",
        "state" => "present",
      })

      result["failed"].as_bool.must_equal(true)
      # The non-existent `nope` dir is filtered out (os.path.exists gate);
      # the existing one leads the list, then $PATH follows.
      msg = result["msg"].as_s
      msg.starts_with?("Failed to find required executable \"brew\" in paths: #{real_dir}:").must_equal(true, msg)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "fails an out-of-spec state with the argspec wording before the brew lookup" do
    result = PluginSpecHelper.run("homebrew_cask", {"name" => "atom", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of state must be one of: present, installed, latest, upgraded, absent, removed, uninstalled, got: bogus"
    )
  end

  it "fails an invalid path with the crash shape (chain inside the msg)" do
    result = PluginSpecHelper.run("homebrew_cask", {"name" => "atom", "path" => "/bad!path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: Invalid path: ['/bad!path']."
    )
    result["_ansible_error_detail"].as_s.must_equal("Invalid path: ['/bad!path'].")
  end

  it "fails an invalid cask name with the bare fail_json shape" do
    with_brew_shim do |_dir, bin_dir|
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"  => "foo;bar",
        "path"  => bin_dir,
        "state" => "present",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Invalid cask: foo;bar.")
    end
  end

  it "installs a missing cask and reports it changed" do
    with_brew_shim do |_dir, bin_dir|
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"  => "foo",
        "path"  => bin_dir,
        "state" => "present",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Cask installed: foo")
    end
  end

  it "reports an already-installed cask unchanged" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.touch(File.join(dir, "state", "foo"))
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"  => "foo",
        "path"  => bin_dir,
        "state" => "present",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Cask already installed: foo")
    end
  end

  it "only reports a would-be install in check mode without installing" do
    with_brew_shim do |dir, bin_dir|
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"                => "foo",
        "path"                => bin_dir,
        "state"               => "present",
        "_ansible_check_mode" => "true",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Cask would be installed: foo")
      # The mutating command never ran - the shim creates the state file
      # only inside `install`.
      File.exists?(File.join(dir, "state", "foo")).must_equal(false)
    end
  end

  it "summarizes a multi-cask result as Changed/Unchanged counts" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.touch(File.join(dir, "state", "foo"))
      File.touch(File.join(dir, "state", "bar"))
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"  => "foo,bar",
        "path"  => bin_dir,
        "state" => "present",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Changed: 0, Unchanged: 2")
    end
  end

  it "reports an already-uninstalled cask for state absent" do
    with_brew_shim do |_dir, bin_dir|
      result = PluginSpecHelper.run("homebrew_cask", {
        "name"  => "foo",
        "path"  => bin_dir,
        "state" => "absent",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Cask already uninstalled: foo")
    end
  end

  it "reports casks would be upgraded for upgrade_all in check mode" do
    with_brew_shim do |_dir, bin_dir|
      result = PluginSpecHelper.run("homebrew_cask", {
        "path"                => bin_dir,
        "upgrade_all"         => "true",
        "_ansible_check_mode" => "true",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Casks would be upgraded.")
    end
  end
end

describe "homebrew_cask resolution" do
  it "resolves the builtin spelling to a real plugin, not an unimplemented-module warning" do
    playbook = Krikri::PlaybookParser.parse_string(
      "- name: issue 1587 repro play\n" \
      "  hosts: all\n" \
      "  tasks:\n" \
      "    - name: Install Atom editor\n" \
      "      homebrew_cask:\n" \
      "        name: atom\n" \
      "        state: present\n"
    )
    task = playbook.plays[0].tasks[0]
    task.module_name.must_equal("ansible.builtin.homebrew_cask")
    task.unavailable_module.must_equal(nil)
    # parse-time validate() is the source of the "uses unimplemented
    # plugin" console warning - a ported module must not appear there.
    Krikri::PlaybookParser.validate(playbook).must_equal([] of String)
    Krikri::PluginManager.simple_plugin_name("ansible.builtin.homebrew_cask").must_equal("homebrew_cask")
  end
end

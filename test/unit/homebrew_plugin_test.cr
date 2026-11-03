require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/homebrew.cr, pinned against real
# community.general.homebrew (live-probed vs ansible-playbook 2.19.11 on
# this host for the failure shapes; issue #777's round evidence for the
# brew-missing shape): ansible-core 2.19 redirects the
# ansible.builtin.homebrew spelling to community.general.homebrew and RUNS
# it, so the old graceful unavailable-module skip diverged on
# rooland-provisioning.git-gpg - real fails the task with get_bin_path's
# wording and stops the play (rc=2) where krikri skipped (rc=4).
#
# Shape facts pinned here (all live-verified or source-derived from the
# module):
# - a missing brew fails with get_bin_path's exact wording; the reported
#   path list is the `path:` value's EXISTING dirs first, then $PATH, then
#   the existing sbin dirs basic.py appends - non-existent opt_dirs are
#   filtered out (os.path.exists gate);
# - `state:` outside the argument spec's choices fails with the argspec
#   wording BEFORE the brew lookup (module setup precedes main());
# - an invalid `path:` (characters outside VALID_BREW_PATH_CHARS) fails
#   with the path setter's HomebrewException escaping main() - the
#   uncaught-exception crash shape whose result msg carries the whole
#   "Task failed: Module failed: ..." chain (live-verified: unlike a
#   fail_json result, whose msg stays bare);
# - with brew resolvable, state=present installs what `brew info
#   --json=v2` reports as not installed and reports the already-installed
#   set unchanged; multi-package results summarize "Changed: N, Unchanged:
#   M" (Homebrew.run's tail); check mode reports "would be installed" and
#   never runs the mutating command;
# - state=absent uninstalls only the installed intersection;
# - names outside VALID_PACKAGE_CHARS fail before any brew command runs.
describe "homebrew plugin" do
  # A fake `brew` whose behavior the tests control through marker files:
  # a package is "installed" when state/<pkg> exists, "outdated" when
  # state/.outdated-<pkg> exists; update echoes the contents of
  # .update-out when present (else "Already up-to-date."); a .fail-info
  # marker makes `info` exit 1 with an error on stderr.
  BREW_SHIM = <<-'SHIM'
    #!/bin/bash
    dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    state="$dir/state"
    mkdir -p "$state"
    cmd="$1"; shift
    case "$cmd" in
      info)
        if [ -f "$state/.fail-info" ]; then echo "Error: info failed" >&2; exit 1; fi
        printf '{"formulae": ['
        first=1
        for n in "$@"; do
          case "$n" in --*) continue ;; esac
          [ $first = 0 ] && printf ', '
          first=0
          if [ -f "$state/$n" ]; then
            inst='[{}]'
            outdated=$([ -f "$state/.outdated-$n" ] && echo true || echo false)
          else
            inst='[]'
            outdated=false
          fi
          printf '{"name": "%s", "full_name": "%s", "tap": "homebrew/core", "aliases": [], "oldnames": [], "installed": %s, "outdated": %s}' "$n" "$n" "$inst" "$outdated"
        done
        printf '], "casks": []}\n'
        exit 0 ;;
      install)
        for n in "$@"; do case "$n" in --*) continue ;; esac; touch "$state/$n"; done
        exit 0 ;;
      upgrade)
        for n in "$@"; do
          case "$n" in --*) continue ;; esac
          touch "$state/$n"
          rm -f "$state/.outdated-$n"
        done
        exit 0 ;;
      uninstall)
        for n in "$@"; do case "$n" in --*) continue ;; esac; rm -f "$state/$n"; done
        exit 0 ;;
      update)
        if [ -f "$state/.update-out" ]; then cat "$state/.update-out"; else echo "Already up-to-date."; fi
        exit 0 ;;
      link) exit 0 ;;
      unlink) exit 0 ;;
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
    dir = PluginSpecHelper.tmp_path("homebrew-shim")
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    File.write(File.join(bin_dir, "brew"), BREW_SHIM)
    File.chmod(File.join(bin_dir, "brew"), 0o755)
    yield dir, bin_dir
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  it "fails a missing brew with get_bin_path's wording, existing opt_dirs first" do
    dir = PluginSpecHelper.tmp_path("homebrew-missing")
    begin
      real_dir = File.join(dir, "real")
      FileUtils.mkdir_p(real_dir)
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "git",
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
    result = PluginSpecHelper.run("homebrew", {"name" => "git", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of state must be one of: present, installed, latest, upgraded, head, linked, unlinked, absent, removed, uninstalled, got: bogus"
    )
  end

  it "fails an invalid path with the crash shape (chain inside the msg)" do
    result = PluginSpecHelper.run("homebrew", {"name" => "git", "path" => "/bad!path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: Invalid path: ['/bad!path']."
    )
    result["_ansible_error_detail"].as_s.must_equal("Invalid path: ['/bad!path'].")
  end

  it "installs a missing package and reports it changed" do
    with_brew_shim do |_dir, bin_dir|
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "foo",
        "path"  => bin_dir,
        "state" => "present",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Package installed: foo")
      result["changed_pkgs"].as_a.map(&.as_s).must_equal(["foo"])
      result["unchanged_pkgs"].as_a.size.must_equal(0)
    end
  end

  it "reports an already-installed package unchanged" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.touch(File.join(dir, "state", "foo"))
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "foo",
        "path"  => bin_dir,
        "state" => "present",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Package already installed: foo")
      result["unchanged_pkgs"].as_a.map(&.as_s).must_equal(["foo"])
    end
  end

  it "summarizes a multi-package result as Changed/Unchanged counts" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.touch(File.join(dir, "state", "foo"))
      File.touch(File.join(dir, "state", "bar"))
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "foo,bar",
        "path"  => bin_dir,
        "state" => "present",
      })

      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Changed: 0, Unchanged: 2")
      result["unchanged_pkgs"].as_a.size.must_equal(2)
    end
  end

  it "only reports would-be changes in check mode without installing" do
    with_brew_shim do |dir, bin_dir|
      state_dir = File.join(dir, "state")
      result = PluginSpecHelper.run("homebrew", {
        "name"                => "foo",
        "path"                => bin_dir,
        "state"               => "present",
        "_ansible_check_mode" => "true",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Package would be installed: foo")
      # The mutating command never ran - the shim creates the state file
      # only inside `install`.
      File.exists?(File.join(state_dir, "foo")).must_equal(false)
    end
  end

  it "uninstalls only the installed intersection for state absent" do
    with_brew_shim do |dir, bin_dir|
      state_dir = File.join(dir, "state")
      FileUtils.mkdir_p(state_dir)
      File.touch(File.join(state_dir, "foo"))
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "foo,bar",
        "path"  => bin_dir,
        "state" => "absent",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      # changed_pkgs(1) + unchanged_pkgs(1) crosses run()'s summary
      # threshold - the per-branch message is replaced by the counts.
      result["msg"].as_s.must_equal("Changed: 1, Unchanged: 1")
      result["changed_pkgs"].as_a.map(&.as_s).must_equal(["foo"])
      File.exists?(File.join(state_dir, "foo")).must_equal(false)
    end
  end

  it "fails a package name outside VALID_PACKAGE_CHARS after the brew lookup" do
    with_brew_shim do |_dir, bin_dir|
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "foo;bar",
        "path"  => bin_dir,
        "state" => "present",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Invalid package: foo;bar")
    end
  end

  it "fails the brew info probe with the module's stderr wording" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.touch(File.join(dir, "state", ".fail-info"))
      result = PluginSpecHelper.run("homebrew", {
        "name"  => "foo",
        "path"  => bin_dir,
        "state" => "present",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Error: info failed")
    end
  end

  it "carries the update_homebrew flow's own message when no packages are named" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", ".update-out"), "Updated Homebrew from abc123 to def456.\n")
      result = PluginSpecHelper.run("homebrew", {
        "path"            => bin_dir,
        "update_homebrew" => "true",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Homebrew updated successfully.")
    end
  end

  it "reports Homebrew already up-to-date when update's output says so" do
    with_brew_shim do |dir, bin_dir|
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", ".update-out"), "Already up-to-date.\n")
      result = PluginSpecHelper.run("homebrew", {
        "path"            => bin_dir,
        "update_homebrew" => "true",
      })

      has_failed_key?(result).must_equal(false)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Homebrew already up-to-date.")
    end
  end
end

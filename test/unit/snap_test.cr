require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/snap.cr's registered-result KEY ORDER and
# key SET, pinned against the round-1100100 real-host probe captures
# (~/scratch/probe-evidence/1100100_atlantic_local_kop_snap, Ansible =
# the oracle) plus local ansible-core 2.19.11 runs of the installed
# community.general snap module against the same `snap` shim for the
# paths the probe round did not cover (check mode on a not-installed
# snap, channel-mismatch refresh, options, enable/disable quirks,
# install/remove failure skeletons).
#
# Shape facts pinned here (all live-verified):
# - success results carry NO msg key, but DO carry `failed: false`
#   (StateModuleHelper backfills output["failed"] = False), with
#   `changed` first and `failed` last;
# - `version` (dict of `snap version` two-token lines, in output order)
#   is always returned; state=present results also carry `classic` and
#   `channel` before it, ordered channel-then-classic when the task
#   passes `channel:` at all (empirically the VarDict param order the
#   controller hands the module), classic-then-channel otherwise;
# - `snap_names` follows, then `snaps_installed` / `snaps_removed` /
#   `snaps_enabled` / `snaps_disabled` and the `cmd` repr (Python repr
#   of the param-name list + actionable names; joined with "; " per
#   name when classic or a non-stable channel meets multiple snaps)
#   only when something was actionable and not in check mode;
# - a name `snap info` cannot resolve crashes the real module with
#   IndexError - the registered result is the module_fails_on_exception
#   skeleton [output, vars, <output vars>, failed, msg, changed,
#   exception] with msg "Module failed with exception: list index out
#   of range" and the output vars accumulated up to the crash point
#   (`channel` still null there, since __quit_module__'s "stable"
#   default never ran);
# - `state: absent` of a never-installed snap is a no-op SUCCESS, and
#   `state: disabled` of one too (is_snap_enabled's None is falsy),
#   while `state: enabled` of one tries `snap enable` and fails.

private SNAP_SHIM = <<-'SHIM'
  #!/bin/bash
  STATE=__STATE__
  cmd="$1"; shift
  case "$cmd" in
    version) printf 'snap    2.55.3+22.04ubuntu1\nsnapd   2.55.3+22.04ubuntu1\nseries  16\nubuntu  22.04\nkernel  5.15.0-33-generic\n'; exit 0 ;;
    list)
      if [ -z "$1" ]; then
        echo "Name     Version  Rev  Tracking       Publisher  Notes"
        for f in "$STATE"/[a-z]*; do
          [ -e "$f" ] || continue
          n=$(basename "$f")
          printf '%-10s %-8s %-4s %-14s %-10s %s\n' "$n" 6.4 29 latest/stable 'canonical*' "$([ -e "$STATE/.dis-$n" ] && echo disabled || echo -)"
        done
        exit 0
      fi
      n="$1"
      if [ -e "$STATE/$n" ]; then
        echo "Name     Version  Rev  Tracking       Publisher  Notes"
        printf '%-10s %-8s %-4s %-14s %-10s %s\n' "$n" 6.4 29 latest/stable 'canonical*' "$([ -e "$STATE/.dis-$n" ] && echo disabled || echo -)"
        exit 0
      fi
      echo "error: snap \"$n\" not found" >&2
      exit 1 ;;
    info)
      first=1
      for n in "$@"; do
        [ $first = 0 ] && echo "---"
        first=0
        case " hello-world core20 " in *" $n "*) echo "name: $n"; continue ;; esac
        [ -e "$STATE/$n" ] && { echo "name: $n"; continue; }
        echo "warning: no snap found for \"$n\""
      done
      exit 0 ;;
    get)
      [ "$1" = "-d" ] && shift
      n="$1"
      if [ -f "$STATE/.opts-$n" ]; then cat "$STATE/.opts-$n"; else echo '{}'; fi
      exit 0 ;;
    install)
      while [[ "$1" == --* ]]; do shift; done
      for n in "$@"; do [ -e "$STATE/$n" ] || touch "$STATE/$n"; done
      exit 0 ;;
    remove) for n in "$@"; do rm -f "$STATE/$n"; done; exit 0 ;;
    disable) touch "$STATE/.dis-$1"; exit 0 ;;
    enable) rm -f "$STATE/.dis-$1"; exit 0 ;;
    set)
      n="$1"; shift
      out="{"; sep=""
      for p in "$@"; do
        k="${p%%=*}"; v="${p#*=}"
        out="$out$sep\"$k\":\"$v\""; sep=","
      done
      printf '%s\n' "$out}" > "$STATE/.opts-$n"
      exit 0 ;;
    *) exit 0 ;;
  esac
  SHIM

private def with_snap_shim(*installed, &)
  dir = PluginSpecHelper.tmp_path("snap-shim")
  bin_dir = File.join(dir, "bin")
  state = File.join(dir, "state")
  FileUtils.mkdir_p([bin_dir, state])
  installed.each { |snap_name| File.touch(File.join(state, snap_name)) }
  File.write(File.join(bin_dir, "snap"), SNAP_SHIM.gsub("__STATE__", state))
  File.chmod(File.join(bin_dir, "snap"), 0o755)
  env = {"PATH" => "#{bin_dir}:/usr/bin:/bin"}.to_json
  yield env, state
ensure
  FileUtils.rm_rf(dir) if dir
end

private def run_snap(params : Hash(String, String), env : String)
  PluginSpecHelper.run("snap", params.merge({"_environment" => env}))
end

describe "snap plugin registered-result shapes (round-1100100 oracle)" do
  it "installs a fresh snap with the changed shape, cmd repr and no msg" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "present"}, env)

      result.as_h.keys.must_equal(["changed", "classic", "channel", "version",
                                   "snap_names", "snaps_installed", "cmd", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["classic"].as_bool.must_equal(false)
      result["channel"].as_s.must_equal("stable")
      result["version"].as_h.keys.must_equal(["snap", "snapd", "series", "ubuntu", "kernel"])
      result["version"]["snap"].as_s.must_equal("2.55.3+22.04ubuntu1")
      result["version"]["kernel"].as_s.must_equal("5.15.0-33-generic")
      result["snap_names"].as_a.map(&.as_s).must_equal(["hello-world"])
      result["snaps_installed"].as_a.map(&.as_s).must_equal(["hello-world"])
      result["cmd"].as_s.must_equal("['state', 'classic', 'channel', 'dangerous', 'hello-world']")
      result["failed"].as_bool.must_equal(false)
      result["msg"]?.must_be_nil
    end
  end

  it "is idempotent for an already-installed snap with the ok shape" do
    with_snap_shim("hello-world") do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "present"}, env)

      result.as_h.keys.must_equal(["changed", "classic", "channel", "version", "snap_names", "failed"])
      result["changed"].as_bool.must_equal(false)
      result["snaps_installed"]?.must_be_nil
      result["msg"]?.must_be_nil
    end
  end

  it "emits channel-then-classic order when the task passes channel: at all" do
    with_snap_shim("hello-world") do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "present", "channel" => "stable"}, env)

      result.as_h.keys.must_equal(["changed", "channel", "classic", "version", "snap_names", "failed"])
      result["channel"].as_s.must_equal("stable")
    end
  end

  it "refreshes on a channel mismatch with the changed shape" do
    with_snap_shim("hello-world") do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "present", "channel" => "edge"}, env)

      result.as_h.keys.must_equal(["changed", "channel", "classic", "version",
                                   "snap_names", "snaps_installed", "cmd", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["channel"].as_s.must_equal("edge")
      result["cmd"].as_s.must_equal("['state', 'classic', 'channel', 'dangerous', 'hello-world']")
    end
  end

  it "reports changed plus snaps_installed without cmd in check mode for a not-installed snap" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "core20", "state" => "present",
                         "_ansible_check_mode" => "true"}, env)

      result.as_h.keys.must_equal(["changed", "classic", "channel", "version",
                                   "snap_names", "snaps_installed", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["cmd"]?.must_be_nil
    end
  end

  it "is idempotent in check mode for an installed snap" do
    with_snap_shim("core20") do |env, _|
      result = run_snap({"name" => "core20", "state" => "present",
                         "_ansible_check_mode" => "true"}, env)

      result.as_h.keys.must_equal(["changed", "classic", "channel", "version", "snap_names", "failed"])
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "removes an installed snap with the changed shape and classic-channel-state cmd repr" do
    with_snap_shim("hello-world") do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "absent"}, env)

      result.as_h.keys.must_equal(["changed", "version", "snaps_removed", "cmd", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["snaps_removed"].as_a.map(&.as_s).must_equal(["hello-world"])
      result["cmd"].as_s.must_equal("['classic', 'channel', 'state', 'hello-world']")
      result["classic"]?.must_be_nil
      result["channel"]?.must_be_nil
      result["snap_names"]?.must_be_nil
    end
  end

  it "no-ops state=absent for a snap that is not installed" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "absent"}, env)

      result.as_h.keys.must_equal(["changed", "version", "failed"])
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "fails a store-missing name with the module-crash skeleton" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "kop-nonexistent-snap-keyorder", "state" => "present"}, env)

      result.as_h.keys.must_equal(["output", "vars", "version", "failed", "msg", "changed", "exception"])
      result["msg"].as_s.must_equal("Module failed with exception: list index out of range")
      result["changed"].as_bool.must_equal(false)
      result["exception"].as_s.must_equal("(traceback unavailable)")
      # output and vars hold the same accumulated output dict (only
      # `version` - the crash happens before snap_names/set_meta exist)
      result["output"].as_h.keys.must_equal(["version"])
      result["output"].as_h.must_equal(result["vars"].as_h)
      result["version"]["snap"].as_s.must_equal("2.55.3+22.04ubuntu1")
    end
  end

  it "joins per-name cmd reprs with '; ' for a multi-name install without channel" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "hello-world,core20", "state" => "present"}, env)

      # channel is absent from the task, so self.vars.channel is None and
      # None != "stable" makes has_one_pkg_params true -> bundle=False ->
      # one repr per name, "; "-joined (real module quirk, live-verified)
      result["cmd"].as_s.must_equal(
        "['state', 'classic', 'channel', 'dangerous', 'hello-world']; " \
        "['state', 'classic', 'channel', 'dangerous', 'core20']")
      result["snaps_installed"].as_a.map(&.as_s).must_equal(["hello-world", "core20"])
    end
  end

  it "sets options in one snap set call and reports options_changed" do
    with_snap_shim("hello-world") do |env, state|
      result = run_snap({"name" => "hello-world", "state" => "present",
                         "options" => "foo=bar"}, env)

      result.as_h.keys.must_equal(["changed", "classic", "channel", "version",
                                   "snap_names", "options_changed", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["options_changed"].as_a.map(&.as_s).must_equal(["hello-world:foo=bar"])
      File.read(File.join(state, ".opts-hello-world")).strip.must_equal(%({"foo":"bar"}))

      # second run: the stored value matches -> idempotent
      result = run_snap({"name" => "hello-world", "state" => "present",
                         "options" => "foo=bar"}, env)
      result["changed"].as_bool.must_equal(false)
      result["options_changed"]?.must_be_nil
    end
  end

  it "disables and re-enables with the generic-action shape" do
    with_snap_shim("hello-world") do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "disabled"}, env)
      result.as_h.keys.must_equal(["changed", "version", "snaps_disabled", "cmd", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["snaps_disabled"].as_a.map(&.as_s).must_equal(["hello-world"])
      result["cmd"].as_s.must_equal("['classic', 'channel', 'state', 'hello-world']")

      result = run_snap({"name" => "hello-world", "state" => "disabled"}, env)
      result.as_h.keys.must_equal(["changed", "version", "failed"])
      result["changed"].as_bool.must_equal(false)

      result = run_snap({"name" => "hello-world", "state" => "enabled"}, env)
      result.as_h.keys.must_equal(["changed", "version", "snaps_enabled", "cmd", "failed"])
      result["snaps_enabled"].as_a.map(&.as_s).must_equal(["hello-world"])
    end
  end

  it "no-ops state=disabled for a snap that is not installed (None is falsy)" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "disabled"}, env)
      result.as_h.keys.must_equal(["changed", "version", "failed"])
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "fails with the plain validation shape for a bad state" do
    with_snap_shim do |env, _|
      result = run_snap({"name" => "hello-world", "state" => "bogus"}, env)
      result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
      result["msg"].as_s.must_equal("value of state must be one of: absent, present, enabled, disabled, got: bogus")
    end
  end

  it "fails with the plain validation shape for a missing name" do
    with_snap_shim do |env, _|
      result = run_snap({"state" => "present"}, env)
      result["msg"].as_s.must_equal("missing required arguments: name")
    end
  end

  it "fails with get_bin_path wording when snap is not on PATH" do
    with_snap_shim do |_, _|
      result = run_snap({"name" => "hello-world", "state" => "present"},
        %({"PATH": "/usr/bin:/bin"}))
      result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
      result["msg"].as_s.must_match(/^Failed to find required executable "snap" in paths:/)
    end
  end
end

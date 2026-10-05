require "../minitest_helper"
require "file_utils"

# Regression spec for a task that asks for SEVERAL ufw commands at once,
# e.g. the "activate everything in one task" shape konstruktoid.hardening
# uses (round 1000, real Ubuntu 22.04 hosts):
#
#   community.general.ufw:
#     {rule: allow, from_ip: 192.168.1.0/24, to_port: 22, proto: tcp,
#      comment: ansible managed, state: enabled}
#
# Real community.general.ufw's main() builds `commands = {key: params[key]
# for key in command_keys if params[key]}` and then loops over ALL of them
# in command_keys order (state, default, rule, logging) against a SINGLE
# pre state + pre rule-tuple snapshot taken before the loop and a SINGLE
# post snapshot taken after it. This plugin used to dispatch
# first-match-wins with an early return per key, so it ran `ufw -f enable`
# and silently dropped the rule/default/logging - the firewall was never
# actually configured while the task reported success, and `changed`,
# `commands` and `msg` all diverged from real's.
#
# The expected command lists below are the real-side `commands` arrays
# captured from those hosts, with only the binary paths swapped for the
# shims' (real's list carries the get_bin_path-resolved absolute paths;
# the plugin resolves the same way through the shims).
#
# Nothing here runs a real ufw/iptables/systemctl: `ufw` and `grep` are
# shell shims in a temp dir, and `ufw status verbose` is rendered from a
# config file those shims own, so the pre/post state diff real computes
# falls out of the shim's own state the same way it does on a host.

private def with_multi_command_shims(logging : String = "on (low)",
                                     incoming : String = "deny",
                                     outgoing : String = "allow",
                                     &)
  dir = File.join(Dir.tempdir, "krikri-ufw-multi-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  tuples = File.join(dir, "tuples")
  conf = File.join(dir, "conf")
  File.write(tuples, "")
  File.write(conf, "Logging: #{logging}\nDefault: #{incoming} (incoming), #{outgoing} (outgoing), disabled (routed)\n")

  ufw = File.join(dir, "ufw")
  File.write(ufw, <<-SHIM)
  #!/bin/sh
  CONF="$KRIKRI_UFW_CONF"
  if [ "$1" = "status" ]; then
    echo "Status: active"
    cat "$CONF"
    exit 0
  fi
  if [ "$1" = "--version" ]; then echo "ufw 0.36.2"; exit 0; fi
  DRY=""
  if [ "$1" = "--dry-run" ]; then DRY=1; shift; fi
  if [ "$1" = "-f" ]; then
    echo "Firewall skipped (simulated)"
    exit 0
  fi
  if [ "$1" = "default" ]; then
    shift
    POLICY="$1"; shift
    DIR="$1"
    INC=$(sed -n 's/^Default: \\([a-z]*\\) (incoming).*/\\1/p' "$CONF")
    OUT=$(sed -n 's/^Default: [a-z]* (incoming), \\([a-z]*\\) (outgoing).*/\\1/p' "$CONF")
    RTE=$(sed -n 's/^Default: [a-z]* (incoming), [a-z]* (outgoing), \\([a-z]*\\) (routed).*/\\1/p' "$CONF")
    case "$DIR" in
      outgoing) OUT="$POLICY" ;;
      routed) RTE="$POLICY" ;;
      *) INC="$POLICY" ;;
    esac
    sed "s/^Default: .*/Default: $INC (incoming), $OUT (outgoing), $RTE (routed)/" "$CONF" > "$CONF.new"
    mv "$CONF.new" "$CONF"
    echo "Default policy changed"
    exit 0
  fi
  if [ "$1" = "logging" ]; then
    shift
    case "$1" in
      off) VALUE="off" ;;
      on) VALUE="on" ;;
      *) VALUE="on ($1)" ;;
    esac
    sed "s/^Logging: .*/Logging: $VALUE/" "$CONF" > "$CONF.new"
    mv "$CONF.new" "$CONF"
    echo "Logging updated"
    exit 0
  fi
  if grep -qF "### tuple $*" "$KRIKRI_UFW_TUPLES"; then
    echo "Skipping adding existing rule"
  elif [ -n "$DRY" ]; then
    echo "Rules updated"
    echo "Rules updated (v6)"
    cat "$KRIKRI_UFW_TUPLES"
    echo "### tuple $*"
  else
    echo "### tuple $*" >> "$KRIKRI_UFW_TUPLES"
    echo "Rule added"
  fi
  exit 0
  SHIM
  grep = File.join(dir, "grep")
  File.write(grep, <<-SHIM)
  #!/bin/sh
  if [ "$1" = "-h" ]; then
    shift
    [ -s "$KRIKRI_UFW_TUPLES" ] && cat "$KRIKRI_UFW_TUPLES"
    exit 0
  fi
  exec /bin/grep "$@"
  SHIM
  File.chmod(ufw, 0o755)
  File.chmod(grep, 0o755)

  env = {
    "PATH"              => "#{dir}:/usr/bin:/bin",
    "KRIKRI_UFW_TUPLES" => tuples,
    "KRIKRI_UFW_CONF"   => conf,
  }.to_json
  yield env, ufw, grep, dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def ufw_grep_cmd(grep_bin : String) : String
  "#{grep_bin} -h '^### tuple' /lib/ufw/user.rules /lib/ufw/user6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /var/lib/ufw/user.rules /var/lib/ufw/user6.rules"
end

private def ufw_status_cmd(ufw_bin : String) : String
  "#{ufw_bin} status verbose"
end

# `post` mirrors real ufw.py's tail: :both = the post status snapshot plus
# the post rule-tuple read (taken only while nothing has counted as
# changed), :status = the status snapshot alone (something already did),
# Observed behavior: none = check mode, which exits before any post probe.
private def ufw_trace(ufw_bin : String, grep_bin : String, middle : Array(String), post : Symbol = :both) : Array(String)
  trace = [ufw_status_cmd(ufw_bin), ufw_grep_cmd(grep_bin)]
  middle.each { |cmd| trace << cmd }
  case post
  when :both
    trace << ufw_status_cmd(ufw_bin)
    trace << ufw_grep_cmd(grep_bin)
  when :status
    trace << ufw_status_cmd(ufw_bin)
  end
  trace
end

describe "ufw plugin runs every requested command, like real ufw.py's command loop" do
  it "runs state then rule in one task, with the version probe between them" do
    with_multi_command_shims do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "rule"         => "allow",
        "from_ip"      => "192.168.0.0/24",
        "to_port"      => "22",
        "proto"        => "tcp",
        "comment"      => "ansible managed",
        "state"        => "enabled",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      # msg is the FINAL `ufw status verbose` snapshot, never a command's
      # own output - the logging/default edits it shows are the shim's
      # own config, exactly what real would report.
      result["msg"].as_s.must_equal("Status: active\nLogging: on (low)\nDefault: deny (incoming), allow (outgoing), disabled (routed)")
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [
        "#{ufw_bin} -f enable",
        "#{ufw_bin} --version",
        "#{ufw_bin} allow from 192.168.0.0/24 to any port 22 proto tcp comment 'ansible managed'",
      ]))
    end
  end

  it "reports changed=false for state+default+logging when the default and log level already match" do
    with_multi_command_shims do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "state"        => "enabled",
        "direction"    => "incoming",
        "default"      => "deny",
        "logging"      => "low",
        "comment"      => "ansible managed",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [
        "#{ufw_bin} -f enable",
        "#{ufw_bin} default deny incoming",
        "#{ufw_bin} logging low",
      ]))
    end
  end

  it "reports changed=true for state+default+logging when the default actually moves the state" do
    with_multi_command_shims do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "state"        => "enabled",
        "direction"    => "outgoing",
        "default"      => "deny",
        "logging"      => "low",
        "comment"      => "ansible managed",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [
        "#{ufw_bin} -f enable",
        "#{ufw_bin} default deny outgoing",
        "#{ufw_bin} logging low",
      ]))
    end
  end

  it "runs default and logging without a state, default first" do
    with_multi_command_shims do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "direction"    => "outgoing",
        "default"      => "deny",
        "logging"      => "high",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [
        "#{ufw_bin} default deny outgoing",
        "#{ufw_bin} logging high",
      ], post: :status))
    end
  end

  it "runs rule and logging without a state, the version probe still first" do
    with_multi_command_shims do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "rule"         => "allow",
        "to_port"      => "22",
        "logging"      => "low",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [
        "#{ufw_bin} --version",
        "#{ufw_bin} allow from any to any port 22",
        "#{ufw_bin} logging low",
      ]))
    end
  end

  it "in check mode runs no command at all but still reports the default as changed" do
    with_multi_command_shims(logging: "on (low)", outgoing: "deny") do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "state"               => "enabled",
        "direction"           => "outgoing",
        "default"             => "allow",
        "logging"             => "low",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.must_be_nil
      # Real's check-mode exit_json carries no msg key at all.
      result["msg"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "commands"])
      result["changed"].as_bool.must_equal(true)
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [] of String, post: :none))
    end
  end

  it "in check mode with state and rule skips the state command but still probes the version and the dry run" do
    with_multi_command_shims do |env, ufw_bin, grep_bin, _|
      result = PluginSpecHelper.run("ufw", {
        "rule"                => "allow",
        "to_port"             => "22",
        "proto"               => "tcp",
        "state"               => "enabled",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.must_be_nil
      result["msg"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["commands"].as_a.map(&.as_s).must_equal(ufw_trace(ufw_bin, grep_bin, [
        "#{ufw_bin} --version",
        "#{ufw_bin} --dry-run allow from any to any port 22 proto tcp",
      ], post: :none))
    end
  end
end

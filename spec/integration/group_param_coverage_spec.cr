require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the group module's remaining
# real-Ansible options: force, local, non_unique, gid_min, gid_max.
#
# Every command shape and every failure message asserted below was
# live-verified against real ansible-core 2.19.4 (the distro's own
# /usr/lib/python3/dist-packages/ansible/modules/group.py run with
# PATH-shimmed group tools and the host's real /etc/group), e.g.:
#   groupadd -g 1234 -o -r -K GID_MIN=500 -K GID_MAX=1000 g1
#   groupmod -g 4711 -o root
#   groupdel -f root
#   lgroupadd -r g1-sys-xyz
#   lgroupmod -g 4711 root
#   lgroupdel root
#   "non_unique is True but all of the following are missing: gid"
#   "force is not a valid option for local, force=True and local=True are
#    mutually exclusive"
#   "'gid_min' can not be used with 'local'" (and the gid_max twin)
#   "GID '4' already exists with group 'adm'"
# plus the real module's gid-0 quirk (its Python `if self.gid:` skips the
# local gid-in-use check for gid 0).
#
# The plugin talks to the host only through #remote_exec, so every
# example here runs the REAL plugin binary against shim binaries (fake
# getent/cat/groupadd/groupmod/groupdel/lgroupadd/lgroupmod/lgroupdel
# first on PATH via the plugin's `_environment` seam, as the user
# param-coverage spec does) and asserts on the argument lines those
# shims log - nothing touches the real group database, and every command
# the plugin would issue is genuinely constructed and observed, not
# shape-matched.

private def with_group_shims(group : String, &)
  dir = File.join(Dir.tempdir, "krikri-group-param-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  fake_group = File.join(dir, "group")
  FileUtils.mkdir_p(dir)
  File.write(fake_group, group)

  shim = File.join(dir, "shims")
  FileUtils.mkdir_p(shim)

  %w[groupadd groupmod groupdel lgroupadd lgroupmod lgroupdel].each do |name|
    File.write(File.join(shim, name), <<-'SHIM')
      #!/bin/sh
      echo "$(basename $0) $*" >> "$KRIKRI_GROUP_LOG"
      exit 0
    SHIM
  end

  File.write(File.join(shim, "getent"), <<-'SHIM')
    #!/bin/sh
    echo "getent $*" >> "$KRIKRI_GROUP_LOG"
    db="$1"; key="$2"
    if [ "$db" = "group" ]; then
      if [ -n "$key" ]; then grep "^$key:" "$KRIKRI_FAKE_GROUP" && exit 0; exit 2; fi
      exec /bin/cat "$KRIKRI_FAKE_GROUP"
    fi
    exit 2
  SHIM

  File.write(File.join(shim, "cat"), <<-'SHIM')
    #!/bin/sh
    case "$1" in
      /etc/group) exec /bin/cat "$KRIKRI_FAKE_GROUP" ;;
      *) exec /bin/cat "$@" ;;
    esac
  SHIM

  %w[groupadd groupmod groupdel lgroupadd lgroupmod lgroupdel getent cat].each do |name|
    File.chmod(File.join(shim, name), 0o755)
  end

  env = {
    "PATH"              => "#{shim}:/usr/bin:/bin",
    "KRIKRI_GROUP_LOG"  => log,
    "KRIKRI_FAKE_GROUP" => fake_group,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

private def read_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

private def expect_ok(result : JSON::Any) : Nil
  return unless result["failed"].as_bool
  raise "task failed: #{result["msg"]?}"
end

private def call_for(log : String, command : String) : String
  calls = read_calls(log)
  found = calls.find(&.starts_with?("#{command} "))
  raise "expected a #{command} call in: #{calls.join(" | ")}" unless found
  found
end

private EXISTING_GROUP = "root:x:0:\nadm:x:4:labros\nsudo:x:27:labros\n"
private NO_GROUPS      = "root:x:0:\n"

describe "group plugin - parameter coverage" do
  describe "non_unique" do
    it "fails with real Ansible's required_if message when no gid was given (live-verified text)" do
      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "non_unique" => "true", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("non_unique is True but all of the following are missing: gid")
        read_calls(log).none?(&.starts_with?("groupadd")).should be_true
      end
    end

    it "passes -o alongside the gid at creation, and never emits -o without a gid" do
      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid" => "1001", "non_unique" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "groupadd").should contain("-g 1001 -o")
      end
    end

    it "passes -o on a gid CHANGE for an existing group, and nothing when the gid matches" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "adm", "gid" => "4711", "non_unique" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "groupmod").should contain("-g 4711 -o")

        with_group_shims(EXISTING_GROUP) do |env2, log2|
          result = PluginSpecHelper.run("group", {
            "name" => "adm", "gid" => "4", "non_unique" => "true", "_environment" => env2,
          })
          expect_ok(result)
          read_calls(log2).none?(&.starts_with?("groupmod")).should be_true
        end
      end
    end
  end

  describe "force" do
    it "passes -f to groupdel on removal, and nothing on the create path" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "adm", "state" => "absent", "force" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "groupdel").should eq("groupdel -f adm")
      end

      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "force" => "true", "gid" => "1001", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "groupadd").should_not contain("-f")
      end
    end

    it "fails with real Ansible's message when combined with local (live-verified text)" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "adm", "force" => "true", "local" => "true", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("force is not a valid option for local, force=True and local=True are mutually exclusive")
        read_calls(log).none?(&.starts_with?("lgroupdel")).should be_true
      end
    end
  end

  describe "gid_min / gid_max" do
    it "passes them as -K GID_MIN/GID_MAX pairs at creation, in real Ansible's order (live-verified shape)" do
      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid" => "1234", "system" => "true", "non_unique" => "true",
          "gid_min" => "500", "gid_max" => "1000", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "groupadd").should eq("groupadd -g 1234 -o -r -K GID_MIN=500 -K GID_MAX=1000 g1")
      end
    end

    it "applies to the auto-assigned range when no gid is given" do
      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid_min" => "2000", "gid_max" => "2999", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "groupadd").should eq("groupadd -K GID_MIN=2000 -K GID_MAX=2999 g1")
      end
    end

    it "fails with real Ansible's messages when combined with local (live-verified texts)" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid_min" => "500", "local" => "true", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("'gid_min' can not be used with 'local'")

        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid_max" => "1000", "local" => "true", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("'gid_max' can not be used with 'local'")
        read_calls(log).none?(&.starts_with?("lgroupadd")).should be_true
      end
    end
  end

  describe "local" do
    it "checks existence via /etc/group directly (no getent) and creates through lgroupadd" do
      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid" => "4711", "local" => "true", "_environment" => env,
        })
        expect_ok(result)
        read_calls(log).none?(&.starts_with?("getent group g1")).should be_true
        call_for(log, "lgroupadd").should eq("lgroupadd -g 4711 g1")
      end
    end

    it "keeps -r on the local create path (real Ansible passes it to lgroupadd too, live-verified)" do
      with_group_shims(NO_GROUPS) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "system" => "true", "local" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "lgroupadd").should eq("lgroupadd -r g1")
      end
    end

    it "fails with real Ansible's gid-in-use message before any mutation (live-verified text)" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid" => "4", "local" => "true", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("GID '4' already exists with group 'adm'")
        read_calls(log).none?(&.starts_with?("lgroupadd")).should be_true
      end
    end

    it "skips the gid-in-use check for gid 0 (real module's Python `if self.gid:` truthiness, live-verified)" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "g1", "gid" => "0", "local" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "lgroupadd").should contain("-g 0")
      end
    end

    it "applies the same gid-in-use pre-check on the modify path" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "root", "gid" => "4", "local" => "true", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("GID '4' already exists with group 'adm'")
        read_calls(log).none?(&.starts_with?("lgroupmod")).should be_true
      end
    end

    it "modifies and deletes through lgroupmod/lgroupdel (live-verified shapes)" do
      with_group_shims(EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("group", {
          "name" => "root", "gid" => "4711", "local" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "lgroupmod").should eq("lgroupmod -g 4711 root")

        result = PluginSpecHelper.run("group", {
          "name" => "adm", "state" => "absent", "local" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "lgroupdel").should eq("lgroupdel adm")
      end
    end
  end

  it "returns gid/system/name/state like real Ansible whenever the group exists after the task" do
    with_group_shims("root:x:0:\ng1:x:1001:\n") do |env, _log|
      result = PluginSpecHelper.run("group", {
        "name" => "g1", "gid" => "1001", "_environment" => env,
      })
      expect_ok(result)
      result["changed"].as_bool.should be_false
      result["gid"].as_i.should eq(1001)
      result["system"].as_bool.should be_false
      result["name"].as_s.should eq("g1")
      result["state"].as_s.should eq("present")
    end
  end
end

require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the user module's remaining
# real-Ansible options: skeleton, move_home, non_unique, local, umask,
# password_expire_account_disable.
#
# Every flag's exact shape below was live-verified against ansible-core
# 2.19.4 by extracting the real module's AnsiballZ payload and running
# it against PATH-shimmed useradd/usermod/luseradd/lgroupmod/lchage (no
# system mutation), e.g.:
#   useradd -u 60000 -o -e 2030-01-01 -f 30 -m -k /etc/skel.custom -K UMASK=027 <name>
#   usermod -u 60001 -o -d <home> -m -f 30 <name>
#   luseradd -f 30 -k /etc/skel.custom <name>
#   lchage -E 21915 <name>
#   lgroupmod -M <name> sudo
# and the umask+local conflict's exact failure message.
#
# The plugin talks to the host only through #remote_exec, so every
# example here runs the REAL plugin binary against shim binaries (fake
# getent/cat/useradd/usermod/l* first on PATH via the plugin's
# `_environment` seam, as the service param-coverage spec does) and
# asserts on the argument lines those shims log - nothing touches the
# real account database, and every command the plugin would issue is
# genuinely constructed and observed, not shape-matched.

private def with_user_shims(passwd : String, shadow : String, group : String, &)
  dir = File.join(Dir.tempdir, "krikri-user-param-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  fake_passwd = File.join(dir, "passwd")
  fake_shadow = File.join(dir, "shadow")
  fake_group = File.join(dir, "group")
  FileUtils.mkdir_p(dir)
  File.write(fake_passwd, passwd)
  File.write(fake_shadow, shadow)
  File.write(fake_group, group)

  shim = File.join(dir, "shims")
  FileUtils.mkdir_p(shim)

  # chown/cp are shimmed too: the fake account doesn't exist in the real
  # passwd db (so a real chown would always fail as non-root), and the
  # skeleton source is a path only the fake filesystem knows about.
  ["useradd", "usermod", "userdel", "luseradd", "lusermod", "luserdel",
   "lgroupmod", "lchage", "chage", "chown", "cp"].each do |name|
    File.write(File.join(shim, name), <<-'SHIM')
      #!/bin/sh
      echo "$(basename $0) $*" >> "$KRIKRI_USER_LOG"
      exit 0
    SHIM
  end

  File.write(File.join(shim, "getent"), <<-'SHIM')
    #!/bin/sh
    db="$1"; key="$2"
    case "$db" in
      passwd)
        if [ -n "$key" ]; then grep "^$key:" "$KRIKRI_FAKE_PASSWD"; else cat "$KRIKRI_FAKE_PASSWD"; fi
        ;;
      group)
        if [ -n "$key" ]; then grep "^$key:" "$KRIKRI_FAKE_GROUP"; else cat "$KRIKRI_FAKE_GROUP"; fi
        ;;
    esac
  SHIM

  File.write(File.join(shim, "cat"), <<-'SHIM')
    #!/bin/sh
    case "$1" in
      /etc/passwd) exec /bin/cat "$KRIKRI_FAKE_PASSWD" ;;
      /etc/shadow) exec /bin/cat "$KRIKRI_FAKE_SHADOW" ;;
      *) exec /bin/cat "$@" ;;
    esac
  SHIM

  %w[useradd usermod userdel luseradd lusermod luserdel lgroupmod lchage chage getent cat chown cp].each do |name|
    File.chmod(File.join(shim, name), 0o755)
  end

  env = {
    "PATH"               => "#{shim}:/usr/bin:/bin",
    "KRIKRI_USER_LOG"    => log,
    "KRIKRI_FAKE_PASSWD" => fake_passwd,
    "KRIKRI_FAKE_SHADOW" => fake_shadow,
    "KRIKRI_FAKE_GROUP"  => fake_group,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
  # The modify path really mkdir -p's the (fake) relocated home.
  FileUtils.rm_rf(NEW_HOME) if NEW_HOME
end

private def read_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

# Normalizes the logged argv (quotes are consumed by the shim shell's
# own parsing) for substring assertions.

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

private EXISTING_USER = "shim-user"
# Unique per run - an earlier failing attempt must never poison a later
# one (the modify path really mkdir -p's the new home before chown).
private NEW_HOME        = "/tmp/krikri-shim-new-home-#{Random.rand(1_000_000)}"
private EXISTING_PASSWD = "shim-user:x:1001:1001:Shim User:/old/home:/bin/bash\n"
private EXISTING_SHADOW = "shim-user:!:19900:0:99999:7::19000:\n"
private EXISTING_GROUP  = "adm:x:4:shim-user\nsudo:x:27:shim-user\ndocker:x:999:\n"
private NO_USER         = "root:x:0:0:root:/root:/bin/bash\n"
private NO_SHADOW       = "root:!:19900:0:99999:7:::\n"
private NO_GROUP        = "root:x:0:\n"

describe "user plugin - parameter coverage" do
  describe "non_unique" do
    it "passes -o alongside the uid at creation, never without a uid" do
      with_user_shims(NO_USER, NO_SHADOW, NO_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => "shim-new", "uid" => "60000", "non_unique" => "true",
          "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "useradd").should contain("-u 60000 -o")

        with_user_shims(NO_USER, NO_SHADOW, NO_GROUP) do |env2, log2|
          result = PluginSpecHelper.run("user", {
            "name" => "shim-new", "non_unique" => "true",
            "_environment" => env2,
          })
          expect_ok(result)
          call_for(log2, "useradd").should_not contain("-o")
        end
      end
    end

    it "passes -o on a uid CHANGE for an existing user, and nothing when the uid matches" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "uid" => "60001", "non_unique" => "true",
          "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "usermod").should contain("-u 60001 -o")

        with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env2, log2|
          result = PluginSpecHelper.run("user", {
            "name" => EXISTING_USER, "uid" => "1001", "non_unique" => "true",
            "_environment" => env2,
          })
          expect_ok(result)
          result.as_h.has_key?("warnings").should be_false
          read_calls(log2).none?(&.starts_with?("usermod")).should be_true
        end
      end
    end
  end

  describe "skeleton and umask" do
    it "passes skeleton as -k and umask as -K UMASK at creation (live-verified shape)" do
      with_user_shims(NO_USER, NO_SHADOW, NO_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => "shim-new", "home" => NEW_HOME,
          "skeleton" => "/etc/skel.custom", "umask" => "027",
          "_environment" => env,
        })
        expect_ok(result)
        line = call_for(log, "useradd")
        line.should contain("-m")
        line.should contain("-k /etc/skel.custom")
        line.should contain("-K UMASK=027")
      end
    end

    it "silently drops skeleton/umask when create_home is off (real Ansible ignores them there too)" do
      with_user_shims(NO_USER, NO_SHADOW, NO_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => "shim-new", "home" => NEW_HOME,
          "createhome" => "false", "skeleton" => "/etc/skel.custom",
          "umask" => "027", "_environment" => env,
        })
        expect_ok(result)
        line = call_for(log, "useradd")
        line.should contain("-M")
        line.should_not contain("-k")
        line.should_not contain("UMASK")
      end
    end

    it "uses the skeleton dir as the copy source when the modify path creates a relocated home" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "home" => NEW_HOME,
          "skeleton" => "/etc/skel.custom", "_environment" => env,
        })
        expect_ok(result)
        cp = call_for(log, "cp")
        cp.should contain("/etc/skel.custom")
        cp.should contain(NEW_HOME)
      end
    end
  end

  describe "move_home" do
    it "emits -m alongside -d when the home changes (live-verified shape)" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "home" => NEW_HOME, "move_home" => "true",
          "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "usermod").should contain("-d #{NEW_HOME} -m")
      end
    end

    it "never emits -m without move_home (the long-standing default)" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "home" => NEW_HOME,
          "_environment" => env,
        })
        expect_ok(result)
        line = call_for(log, "usermod")
        line.should contain("-d #{NEW_HOME}")
        line.should_not contain("-m")
      end
    end
  end

  describe "password_expire_account_disable" do
    it "goes through as useradd/usermod -f, not chage (live-verified shape)" do
      with_user_shims(NO_USER, NO_SHADOW, NO_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => "shim-new", "password_expire_account_disable" => "30",
          "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "useradd").should contain("-f 30")
        read_calls(log).none?(&.starts_with?("chage ")).should be_true
      end
    end

    it "is re-issued on every modify run even when nothing else differs (real Ansible has no idempotency check for it)" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "password_expire_account_disable" => "30",
          "_environment" => env,
        })
        expect_ok(result)
        result["changed"].as_bool.should be_true
        call_for(log, "usermod").should contain("-f 30")
      end
    end
  end

  describe "local" do
    it "fails with real Ansible's exact message when combined with umask" do
      result = PluginSpecHelper.run("user", {
        "name" => "shim-any", "local" => "true", "umask" => "027",
      })
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("'umask' can not be used with 'local'")
    end

    it "checks /etc/passwd directly (never getent) and uses luseradd/lchage/lgroupmod instead of shadow-utils" do
      with_user_shims(NO_USER, NO_SHADOW, NO_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => "shim-new", "local" => "true", "groups" => "adm,sudo",
          "expires" => "1893456000", "skeleton" => "/etc/skel.custom",
          "password_expire_account_disable" => "30", "_environment" => env,
        })
        expect_ok(result)

        # Existence probe bypasses NSS: cat /etc/passwd, never
        # `getent passwd` (which would find a directory/SSSD account).
        read_calls(log).none?(&.starts_with?("getent passwd")).should be_true

        # Live-verified shape: no -m, no -G, -k/-f still threaded through.
        line = call_for(log, "luseradd")
        line.should contain("-k /etc/skel.custom")
        line.should contain("-f 30")
        line.should_not contain("-m")
        line.should_not contain("-G")

        # Expiry via lchage in whole DAYS (1893456000 // 86400 = 21915),
        # groups via one lgroupmod -M per group, lchage first.
        calls = read_calls(log)
        lchage_idx = calls.index { |entry| entry =~ /\blchage -E 21915 shim-new\b/ }
        lgroupmod_idx = calls.index { |entry| entry == "lgroupmod -M shim-new adm" }
        lchage_idx.should_not be_nil
        lgroupmod_idx.should_not be_nil
        lchage_idx.not_nil!.should be < lgroupmod_idx.not_nil!
        calls.should contain("lgroupmod -M shim-new sudo")
      end
    end

    it "modifies via lusermod (including move_home's -m) and routes expiry through lchage -E" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, NO_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "local" => "true",
          "home" => NEW_HOME, "move_home" => "true",
          "expires" => "1893456000", "_environment" => env,
        })
        expect_ok(result)
        line = call_for(log, "lusermod")
        line.should contain("-d #{NEW_HOME} -m")
        line.should_not contain("-e")
        # shadow's current expire field is 19000; 21915 differs -> lchage
        call_for(log, "lchage").should contain("-E 21915")
      end
    end

    it "adds and removes supplementary groups via lgroupmod -M/-m (one command per group)" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "local" => "true", "groups" => "docker,sudo",
          "_environment" => env,
        })
        expect_ok(result)
        calls = read_calls(log)
        calls.should contain("lgroupmod -M shim-user docker")
        calls.should contain("lgroupmod -m shim-user adm")
        # sudo already present -> untouched
        calls.any?(&.starts_with?("lgroupmod -m shim-user sudo")).should be_false
      end
    end

    it "removes via luserdel" do
      with_user_shims(EXISTING_PASSWD, EXISTING_SHADOW, EXISTING_GROUP) do |env, log|
        result = PluginSpecHelper.run("user", {
          "name" => EXISTING_USER, "state" => "absent", "local" => "true",
          "remove" => "true", "_environment" => env,
        })
        expect_ok(result)
        call_for(log, "luserdel").should contain("-r")
      end
    end
  end
end

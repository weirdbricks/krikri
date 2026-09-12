require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the apt module's remaining
# real-Ansible options: dpkg_options, default_release,
# install_recommends, only_upgrade, force, fail_on_autoremove,
# allow_unauthenticated, allow_downgrade, allow_change_held_packages,
# purge, policy_rc_d (plus the two documented no-ops force_apt_get and
# auto_install_module_deps).
#
# Everything here was verified live on this Debian machine against real
# apt 3.0.3 (`apt-get -s` simulate runs accepting every constructed
# flag combination, --force-yes included, deprecated-warning-only) and
# against the locally installed ansible-core 2.19.4's own apt.py module
# source (/usr/lib/python3/dist-packages/ansible/modules/apt.py) for
# each param's command construction - per-example comments say which
# claim comes from where. The policy_rc_d file lifecycle runs against
# the REAL filesystem via the plugin's `_policy_rc_d_path` spec seam
# (underscore-prefixed internal param, same family as `_environment`;
# /usr/sbin/policy-rc.d itself is root-writable and the spec process
# is unprivileged), so the backup/write/restore behavior below is
# genuinely executed, not shape-matched.

# The dpkg Status-Abbrev the dpkg-query shim reports for the requested
# package: "ii" installed, "un" never installed, "rc" removed with
# config files still on disk.
private def with_apt_param_shims(dpkg_status : String, fail_apt : Bool = false, policy_path : String? = nil, &)
  dir = File.join(Dir.tempdir, "krikri-apt-param-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    if [ -n "$KRIKRI_POLICY_PATH" ]; then
      if [ -f "$KRIKRI_POLICY_PATH" ]; then
        echo "POLICY-DURING-OP:" >> "$KRIKRI_APT_CALLS"
        cat "$KRIKRI_POLICY_PATH" >> "$KRIKRI_APT_CALLS"
      else
        echo "POLICY-DURING-OP:absent" >> "$KRIKRI_APT_CALLS"
      fi
    fi
    case "$1" in
      install|remove|upgrade|dist-upgrade|autoremove|autoclean)
        if [ -n "$KRIKRI_APT_FAIL" ]; then
          echo "E: Krikri simulated apt failure." >&2
          exit 100
        fi
        printf 'Reading package lists...\nBuilding dependency tree...\nReading state information...\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\necho \"$KRIKRI_DPKG_STATUS 1.0-1 $3\"\n")
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "dpkg-query"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {
    "PATH"               => "#{dir}:/usr/bin:/bin",
    "KRIKRI_APT_CALLS"   => log,
    "KRIKRI_DPKG_STATUS" => dpkg_status,
    "KRIKRI_POLICY_PATH" => policy_path || "",
    "KRIKRI_APT_FAIL"    => (fail_apt ? "1" : ""),
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

# The first apt-get invocation in the log (the shim records one line
# per call, args only - the DEBIAN_FRONTEND= prefix, the _environment
# exports, and any shell quoting never reach the log).
private def read_log(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

private def install_call(log : String) : String?
  read_log(log).find(&.starts_with?("install"))
end

private def remove_call(log : String) : String?
  read_log(log).find(&.starts_with?("remove"))
end

private def upgrade_call(log : String) : String?
  read_log(log).find { |line| line.includes?("dist-upgrade") || line.includes?("upgrade --with-new-pkgs") }
end

# apt.py's default: dpkg_options=dict(default=DPKG_OPTIONS) where
# DPKG_OPTIONS = 'force-confdef,force-confold'.
DEFAULT_DPKG_OPTIONS = "-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

describe "apt plugin - parameter coverage" do
  describe "dpkg_options" do
    it "keeps the real-Ansible default (force-confdef,force-confold) when unset" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {"name" => "krikri-fake-pkg", "state" => "present", "_environment" => env})
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg")
      end
    end

    it "expands a custom dpkg_options list into one -o Dpkg::Options::= flag per option (apt.py expand_dpkg_options)" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"          => "krikri-fake-pkg",
          "state"         => "present",
          "dpkg_options"  => "force-confnew,force-config",
          "_environment"  => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-config krikri-fake-pkg")
      end
    end
  end

  describe "install flags (apt.py install() command construction)" do
    it "passes force as --force-yes and fail_on_autoremove as --no-remove before the package list" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"               => "krikri-fake-pkg",
          "state"              => "present",
          "force"              => "true",
          "fail_on_autoremove" => "true",
          "_environment"       => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} --force-yes --no-remove krikri-fake-pkg")
      end
    end

    it "passes allow_unauthenticated/allow_downgrade/allow_change_held_packages as apt-get's --allow-* flags after the package list" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"                         => "krikri-fake-pkg",
          "state"                        => "present",
          "allow_unauthenticated"        => "true",
          "allow_downgrade"              => "true",
          "allow_change_held_packages"   => "true",
          "_environment"                 => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg --allow-unauthenticated --allow-downgrades --allow-change-held-packages")
      end
    end

    it "maps default_release to -t <release> (apt-get's -t / pin-priority target)" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"            => "krikri-fake-pkg",
          "state"           => "present",
          "default_release" => "stable-backports",
          "_environment"    => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg -t stable-backports")
      end
    end

    it "maps install_recommends: false to -o APT::Install-Recommends=no" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"                => "krikri-fake-pkg",
          "state"               => "present",
          "install_recommends"  => "false",
          "_environment"        => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg -o APT::Install-Recommends=no")
      end
    end

    it "maps install_recommends: true to -o APT::Install-Recommends=yes" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"                => "krikri-fake-pkg",
          "state"               => "present",
          "install_recommends"  => "true",
          "_environment"        => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg -o APT::Install-Recommends=yes")
      end
    end

    it "leaves apt's own recommend default alone when install_recommends is unset" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {"name" => "krikri-fake-pkg", "state" => "present", "_environment" => env})
        result["failed"].as_bool.should be_false
        install_call(log).not_nil!.should_not contain("APT::Install-Recommends")
      end
    end

    it "skips never-installed packages entirely when only_upgrade is set (apt.py: not installed and only_upgrade -> continue)" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"          => "krikri-fake-pkg",
          "state"         => "present",
          "only_upgrade"  => "true",
          "_environment"  => env,
        })
        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_false
        install_call(log).should be_nil
      end
    end

    it "passes --only-upgrade for state: latest on an installed package" do
      with_apt_param_shims("ii") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"          => "krikri-fake-pkg",
          "state"         => "latest",
          "only_upgrade"  => "true",
          "_environment"  => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} --only-upgrade krikri-fake-pkg")
      end
    end
  end

  describe "state: absent flags (apt.py remove() command construction)" do
    it "passes purge as --purge and force as --force-yes" do
      with_apt_param_shims("ii") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"         => "krikri-fake-pkg",
          "state"        => "absent",
          "purge"        => "true",
          "force"        => "true",
          "_environment" => env,
        })
        result["failed"].as_bool.should be_false
        remove_call(log).should eq("remove -y #{DEFAULT_DPKG_OPTIONS} --purge --force-yes krikri-fake-pkg")
      end
    end

    it "passes allow_change_held_packages on remove too (apt.py remove() takes it; upgrade() does not)" do
      with_apt_param_shims("ii") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"                       => "krikri-fake-pkg",
          "state"                      => "absent",
          "allow_change_held_packages" => "true",
          "_environment"               => env,
        })
        result["failed"].as_bool.should be_false
        remove_call(log).should eq("remove -y #{DEFAULT_DPKG_OPTIONS} --allow-change-held-packages krikri-fake-pkg")
      end
    end

    it "treats a removed-with-config-files (rc) package as needing removal only when purge is set (apt.py: has_files and purge)" do
      with_apt_param_shims("rc") do |env, log|
        result = PluginSpecHelper.run("apt", {"name" => "krikri-fake-pkg", "state" => "absent", "_environment" => env})
        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_false
        remove_call(log).should be_nil
      end
    end

    it "removes (purges) an rc-state package when purge: true" do
      with_apt_param_shims("rc") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"         => "krikri-fake-pkg",
          "state"        => "absent",
          "purge"        => "true",
          "_environment" => env,
        })
        result["failed"].as_bool.should be_false
        remove_call(log).should_not be_nil
        result["changed"].as_bool.should be_true
      end
    end
  end

  describe "upgrade flags (apt.py upgrade() command construction)" do
    it "passes force/fail_on_autoremove/allow_downgrade and -t default_release on upgrade" do
      with_apt_param_shims("ii") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "upgrade"            => "dist",
          "force"              => "true",
          "fail_on_autoremove" => "true",
          "allow_downgrade"    => "true",
          "default_release"    => "stable",
          "_environment"       => env,
        })
        result["failed"].as_bool.should be_false
        upgrade_call(log).should eq("-y #{DEFAULT_DPKG_OPTIONS} --force-yes --no-remove --allow-downgrades dist-upgrade -t stable")
      end
    end

    it "does not pass only_upgrade or allow_change_held_packages on upgrade (upgrade() takes neither)" do
      with_apt_param_shims("ii") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "upgrade"                    => "yes",
          "only_upgrade"               => "true",
          "allow_change_held_packages" => "true",
          "_environment"               => env,
        })
        result["failed"].as_bool.should be_false
        upgrade_call(log).not_nil!.should_not contain("--only-upgrade")
        upgrade_call(log).not_nil!.should_not contain("--allow-change-held-packages")
      end
    end
  end

  describe "cleanup flags (apt.py cleanup() command construction)" do
    it "applies dpkg_options, purge and force to autoremove/autoclean (apt.py: apt-get -y <dpkg_options> <purge> <force_yes> <operation>)" do
      with_apt_param_shims("ii") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "autoremove"   => "true",
          "autoclean"    => "true",
          "purge"        => "true",
          "force"        => "true",
          "_environment" => env,
        })
        result["failed"].as_bool.should be_false
        lines = File.read_lines(log)
        lines.should contain("-y #{DEFAULT_DPKG_OPTIONS} --purge --force-yes autoremove")
        lines.should contain("-y #{DEFAULT_DPKG_OPTIONS} --purge --force-yes autoclean")
      end
    end
  end

  describe "documented no-ops" do
    # krikri's apt plugin has always been apt-get-only (no aptitude
    # anywhere in its code paths), so force_apt_get - which real
    # Ansible uses to pick apt-get over aptitude - is already-true by
    # construction.
    it "force_apt_get is a no-op by construction (this plugin only ever runs apt-get)" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"           => "krikri-fake-pkg",
          "state"          => "present",
          "force_apt_get"  => "true",
          "_environment"   => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg")
      end
    end

    # Real Ansible's auto_install_module_deps governs installing the
    # python3-apt bindings the MODULE itself needs. This plugin is a
    # native Crystal binary with no Python dependency of its own - there
    # is nothing for the option to govern (the plugin's separate
    # python3-apt emulation for host-state parity is not conditional on
    # it, matching how real playbooks use the option).
    it "auto_install_module_deps is a no-op by architecture (native binary, no python3-apt dependency)" do
      with_apt_param_shims("un") do |env, log|
        result = PluginSpecHelper.run("apt", {
          "name"                      => "krikri-fake-pkg",
          "state"                     => "present",
          "auto_install_module_deps"  => "false",
          "_environment"              => env,
        })
        result["failed"].as_bool.should be_false
        install_call(log).should eq("install -y #{DEFAULT_DPKG_OPTIONS} krikri-fake-pkg")
      end
    end
  end

  describe "policy_rc_d file lifecycle (real filesystem via the _policy_rc_d_path spec seam)" do
    it "installs a policy-rc.d forcing the exit code for the duration of the operation and removes it afterward when none existed" do
      policy_path = File.join(Dir.tempdir, "krikri-policy-rc.d-#{Random.rand(1_000_000)}")
      with_apt_param_shims("un", policy_path: policy_path) do |env, log|
        begin
          result = PluginSpecHelper.run("apt", {
            "name"               => "krikri-fake-pkg",
            "state"              => "present",
            "policy_rc_d"        => "101",
            "_policy_rc_d_path"  => policy_path,
            "_environment"       => env,
          })
          result["failed"].as_bool.should be_false

          # During the apt-get window the file existed with exactly the
          # content real Ansible's __enter__ writes.
          File.read(log).should contain("POLICY-DURING-OP:\n#!/bin/sh\nexit 101\n")
          # After the operation it is gone again (no backup existed).
          File.exists?(policy_path).should be_false
        ensure
          File.delete(policy_path) if File.exists?(policy_path)
        end
      end
    end

    it "restores a pre-existing policy-rc.d byte-for-byte after the operation" do
      policy_path = File.join(Dir.tempdir, "krikri-policy-rc.d-#{Random.rand(1_000_000)}")
      with_apt_param_shims("un", policy_path: policy_path) do |env, log|
        begin
          File.write(policy_path, "#!/bin/sh\nexit 0\n# original site policy\n")
          result = PluginSpecHelper.run("apt", {
            "name"               => "krikri-fake-pkg",
            "state"              => "present",
            "policy_rc_d"        => "101",
            "_policy_rc_d_path"  => policy_path,
            "_environment"       => env,
          })
          result["failed"].as_bool.should be_false

          File.read(log).should contain("POLICY-DURING-OP:\n#!/bin/sh\nexit 101\n")
          File.read(policy_path).should eq("#!/bin/sh\nexit 0\n# original site policy\n")
        ensure
          File.delete(policy_path) if File.exists?(policy_path)
        end
      end
    end

    it "still restores the original policy-rc.d when the apt operation fails" do
      policy_path = File.join(Dir.tempdir, "krikri-policy-rc.d-#{Random.rand(1_000_000)}")
      with_apt_param_shims("un", fail_apt: true, policy_path: policy_path) do |env, log|
        begin
          File.write(policy_path, "ORIGINAL")
          result = PluginSpecHelper.run("apt", {
            "name"               => "krikri-fake-pkg",
            "state"              => "present",
            "policy_rc_d"        => "101",
            "_policy_rc_d_path"  => policy_path,
            "_environment"       => env,
          })
          result["failed"].as_bool.should be_true

          # The forced policy was live during the failed operation...
          File.read(log).should contain("POLICY-DURING-OP:\n#!/bin/sh\nexit 101\n")
          # ...and the original was still restored.
          File.read(policy_path).should eq("ORIGINAL")
        ensure
          File.delete(policy_path) if File.exists?(policy_path)
        end
      end
    end

    it "never touches policy-rc.d when policy_rc_d is not given" do
      policy_path = File.join(Dir.tempdir, "krikri-policy-rc.d-#{Random.rand(1_000_000)}")
      with_apt_param_shims("un", policy_path: policy_path) do |env, log|
        begin
          result = PluginSpecHelper.run("apt", {
            "name"               => "krikri-fake-pkg",
            "state"              => "present",
            "_policy_rc_d_path"  => policy_path,
            "_environment"       => env,
          })
          result["failed"].as_bool.should be_false
          File.read(log).should contain("POLICY-DURING-OP:absent")
          File.exists?(policy_path).should be_false
        ensure
          File.delete(policy_path) if File.exists?(policy_path)
        end
      end
    end
  end
end

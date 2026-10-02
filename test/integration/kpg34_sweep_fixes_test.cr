require "../minitest_helper"
require "json"

# Regression tests for the system/storage module groups a
# krikri-playbook-generator sweep (seed 34) flagged: parted, lvg, lvol,
# firewalld, selinux, sefcontext, filesystem, mount_facts,
# kernel_blacklist, async_status, make and deploy_helper. The expected
# strings are real ansible-playbook 2.19.11's own, captured from local
# runs (ansible_connection=local, no gather caching) or live-verified
# module source; the missing-binary/library gates use a restricted child
# PATH (or a failing python shim) so they stay deterministic on hosts
# that do have the real tools installed.

# An executable shim that fails everything, so the python-library gates
# see an interpreter that cannot import the module under test.
private def write_failing_python_shim(dir : String, name : String) : String
  shim = File.join(dir, name)
  File.write(shim, "#!/bin/sh\nexit 7\n")
  File.chmod(shim, 0o755)
  shim
end

# Whether an executable is findable the way real get_bin_path (and this
# repo's find_required_binary) finds it: PATH plus /sbin, /usr/sbin,
# /usr/local/sbin. The restricted-PATH trick used for the python shims
# cannot hide binaries that live in the fixed sbin dirs, so the
# missing-binary tests only engage on hosts genuinely without the tool.
private def binary_findable?(name : String) : Bool
  paths = (ENV["PATH"]? || "").split(':') + %w[/sbin /usr/sbin /usr/local/sbin]
  paths.any? do |dir|
    candidate = "#{dir}/#{name}"
    File::Info.executable?(candidate) && !File.directory?(candidate)
  end
end

describe "parted plugin - get_bin_path ordering (kpg34)" do
  it "fails with real's executable-not-found message before any device check" do
    return if binary_findable?("parted")

    result = PluginSpecHelper.run("parted", {"device" => "/dev/krikri-no-such-disk"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(%(Failed to find required executable "parted" in paths: ))
  end

  it "still validates state choices before the binary lookup (argspec runs first)" do
    result = PluginSpecHelper.run("parted",
      {"device" => "/dev/krikri-no-such-disk", "state" => "bogus"})

    result["msg"].as_s.must_equal("value of state must be one of: absent, info, present, got: bogus")
  end

  it "reports real's get_device_info script failure when parted exists but the device does not" do
    # Needs the real parted binary on PATH (any dev host has it); the
    # restricted-PATH variants above cover hosts without it.
    unless Process.find_executable("parted")
      return
    end

    result = PluginSpecHelper.run("parted", {"device" => "krikri-no-such-disk", "state" => "info"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Error while getting device information with parted script: " \
      "'#{Process.find_executable("parted").not_nil!} -s -m krikri-no-such-disk -- unit KiB print'")
    result["rc"].as_i64.must_equal(1)
  end
end

describe "lvg plugin - kpg34 arg surface and vgs gate" do
  it "accepts pvresize/remove_extra_pvs/reset_vg_uuid/reset_pv_uuid like real's argspec" do
    result = PluginSpecHelper.run("lvg", {
      "vg"               => "krikri-nosuch-vg",
      "pvs"              => "/dev/krikri-no-such-pv",
      "pvresize"         => "true",
      "remove_extra_pvs" => "false",
      "reset_vg_uuid"    => "true",
      "reset_pv_uuid"    => "false",
    })

    # The parameters are part of the accepted spec: whatever happens
    # downstream (the vgs binary gate on a host without LVM2, the
    # vgcreate attempt on one with it), real's unsupported-params
    # error must be gone.
    result["msg"].as_s.wont_include("Unsupported parameters for (community.general.lvg) module")
  end

  it "still rejects genuinely unknown parameters before the binary gate" do
    result = PluginSpecHelper.run("lvg",
      {"vg" => "vg0", "pvs" => "/dev/sdz99", "bogus_param" => "1"})

    result["msg"].as_s.must_include("Unsupported parameters for (community.general.lvg) module: bogus_param")
  end

  it "accepts state=inactive (real 7.1.0 active/inactive choices)" do
    result = PluginSpecHelper.run("lvg",
      {"vg" => "krikri-nosuch-vg", "state" => "inactive"})

    result["msg"].as_s.wont_include("value of state must be one of")
  end

  it "still rejects an invalid state with real's choice list order" do
    result = PluginSpecHelper.run("lvg",
      {"vg" => "vg0", "pvs" => "/dev/sdz99", "state" => "bogus"})

    result["msg"].as_s.must_equal("value of state must be one of: absent, present, active, inactive, got: bogus")
  end
end

describe "lvol plugin - lvm binary gate (kpg34)" do
  it "fails at the lvm executable lookup before size parsing or VG discovery" do
    return if binary_findable?("lvm")

    result = PluginSpecHelper.run("lvol", {
      "vg"   => "krikri-nosuch-vg",
      "lv"   => "krikri-nosuch-lv",
      "size" => "not-a-size",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(%(Failed to find required executable "lvm" in paths: ))
  end

  it "still validates the argspec before the lvm lookup" do
    result = PluginSpecHelper.run("lvol", {
      "vg"    => "krikri-nosuch-vg",
      "lv"    => "krikri-nosuch-lv",
      "size"  => "not-a-size",
      "state" => "bogus",
    })

    result["msg"].as_s.must_equal("value of state must be one of: absent, present, got: bogus")
  end
end

describe "firewalld plugin - firewall library gate (kpg34)" do
  it "fails with real's missing_required_lib wording plus the version suffix" do
    scratch = PluginSpecHelper.tmp_path("kpg34-fw-shim")
    Dir.mkdir_p(scratch)
    write_failing_python_shim(scratch, "python3.13")

    result = PluginSpecHelper.run("firewalld",
      {"icmp_block" => "aucknm", "immediate" => "false", "offline" => "true", "state" => "present"},
      env: {"PATH" => "#{scratch}:/nonexistent-kpg34-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to import the required Python library \(firewall\) on /)
    result["msg"].as_s.must_match(/\. Version 0\.2\.11 or newer required \(0\.3\.9 or newer for offline operations\)\z/)
  end

  it "fails with real's wording before the offline/permanent and zone checks" do
    scratch = PluginSpecHelper.tmp_path("kpg34-fw-shim2")
    Dir.mkdir_p(scratch)
    write_failing_python_shim(scratch, "python3.13")

    result = PluginSpecHelper.run("firewalld",
      {"icmp_block_inversion" => "false", "immediate" => "true", "offline" => "true",
       "permanent" => "false", "state" => "enabled", "zone" => "zphljt"},
      env: {"PATH" => "#{scratch}:/nonexistent-kpg34-path"})

    # The offline-without-permanent error and the zone resolution both
    # come AFTER the import gate in real's sanity_check ordering.
    result["msg"].as_s.must_match(/\AFailed to import the required Python library \(firewall\) on /)
  end
end

describe "selinux plugin - libselinux-python gate (kpg34)" do
  it "fails with real's missing_required_lib wording before the config-file check" do
    scratch = PluginSpecHelper.tmp_path("kpg34-sel-shim")
    Dir.mkdir_p(scratch)
    write_failing_python_shim(scratch, "python3.13")

    result = PluginSpecHelper.run("selinux",
      {"configfile" => "/tmp/kpg34-nosuch-config", "policy" => "nkhzav", "state" => "enforcing"},
      env: {"PATH" => "#{scratch}:/nonexistent-kpg34-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to import the required Python library \(libselinux-python\) on /)
  end
end

describe "sefcontext plugin - SELinux bindings gates (kpg34)" do
  it "fails with real's libselinux-python wording before the getenforce probe" do
    scratch = PluginSpecHelper.tmp_path("kpg34-sefc-shim")
    Dir.mkdir_p(scratch)
    write_failing_python_shim(scratch, "python3.13")

    result = PluginSpecHelper.run("sefcontext",
      {"reload" => "true", "state" => "absent", "target" => "qzusrb"},
      env: {"PATH" => "#{scratch}:/nonexistent-kpg34-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to import the required Python library \(libselinux-python\) on /)
  end

  it "fails with real's policycoreutils-python wording when only seobject is missing" do
    # This host has the selinux binding but (typically) not seobject -
    # exactly real's second gate. When both are present the gate
    # passes and the module proceeds, so only assert the gate while it
    # is reachable.
    python = Process.find_executable("python3") || Process.find_executable("python")
    flunk("no python on PATH to probe with") unless python
    selinux_ok = Process.run(python, {"-c", "import selinux"},
      output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    seobject_ok = Process.run(python, {"-c", "import seobject"},
      output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    return if selinux_ok && seobject_ok
    return unless selinux_ok

    result = PluginSpecHelper.run("sefcontext",
      {"reload" => "true", "state" => "absent", "target" => "qzusrb"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to import the required Python library \(policycoreutils-python\) on /)
  end
end

describe "filesystem plugin - ufs choice (kpg34)" do
  it "accepts fstype=ufs and fails on the missing device like real" do
    result = PluginSpecHelper.run("filesystem",
      {"dev" => "/tmp/kpg34-no-such-device", "fstype" => "ufs", "opts" => "bdcokw", "resizefs" => "false"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Device /tmp/kpg34-no-such-device not found.")
  end
end

describe "mount_facts plugin - dedup warning format (kpg34)" do
  it "renders real's Python-list-repr duplicates wording" do
    source = PluginSpecHelper.tmp_path("kpg34-mounts", "custom")
    Dir.mkdir_p(File.dirname(source))
    File.write(source, "/dev/a /dup ext4 defaults 0 0\n/dev/b /dup ext4 defaults 0 0\n/dev/c /other ext4 defaults 0 0\n")

    result = PluginSpecHelper.run("mount_facts", {"sources" => "[\"#{source}\"]"})

    warnings = result["warnings"]?.try(&.as_a?) || [] of JSON::Any
    text = warnings.map(&.as_s).join("\n")
    text.must_include("mount_facts: ignoring repeat mounts in the following sources: #{source} (['/dup', '/dup', '/other'])")
  end
end

describe "kernel_blacklist plugin - failure result surface (kpg34)" do
  it "carries real's filename/name/state/output/vars keys on the OSError failure" do
    file = PluginSpecHelper.tmp_path("kpg34-no-such-dir", "blacklist-ansible.conf")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "ocgcbu", "blacklist_file" => file})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Module failed with exception: [Errno 2] No such file or directory: '#{file}'")
    result["filename"].as_s.must_equal(file)
    result["name"].as_s.must_equal("ocgcbu")
    result["state"].as_s.must_equal("present")
    result["output"]["filename"].as_s.must_equal(file)
    result["output"]["name"].as_s.must_equal("ocgcbu")
    result["output"]["state"].as_s.must_equal("present")
    result["vars"]["name"].as_s.must_equal("ocgcbu")
  end
end

describe "async_status plugin - not-found result surface (kpg34)" do
  it "carries results_file and the empty stdout/stderr pairs like real" do
    result = PluginSpecHelper.run("async_status", {"jid" => "bpacqp"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("could not find job")
    result["ansible_job_id"].as_s.must_equal("bpacqp")
    result["results_file"].as_s.must_match(/\/\.ansible_async\/bpacqp\z/)
    result["started"].as_bool.must_equal(true)
    result["finished"].as_bool.must_equal(true)
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("")
    result["stdout_lines"].as_a.must_equal([] of JSON::Any)
    result["stderr_lines"].as_a.must_equal([] of JSON::Any)
  end
end

describe "make plugin - unspawnable explicit make binary (kpg34)" do
  it "reports real's run_command OSError shape at the -q check" do
    missing = PluginSpecHelper.tmp_path("kpg34-no-such-make")

    result = PluginSpecHelper.run("make", {
      "chdir"  => "/tmp/kpg34-no-such-chdir",
      "jobs"   => "32",
      "make"   => missing,
      "target" => "qnurdb",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["rc"].as_i64.must_equal(2)
    result["cmd"].as_s.must_equal("#{missing} -j 32 qnurdb -q")
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("")
  end

  it "drops an invalid chdir like real's ignore_invalid_cwd instead of failing on it" do
    # /bin/true as the make binary: the -q check succeeds (exit 0), so
    # the module reports a clean no-op - what must NOT happen is the
    # old `cd: no such file or directory` shell failure this plugin
    # produced when the chdir directory didn't exist.
    result = PluginSpecHelper.run("make", {
      "chdir"  => "/tmp/kpg34-no-such-chdir",
      "make"   => "/bin/true",
      "target" => "krikri-no-such-target",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
    result["command"].as_s.must_equal("/bin/true krikri-no-such-target")
  end
end

describe "deploy_helper plugin - finalize without the release tree (kpg34)" do
  it "reports real's module-crash OSError wording with paths joined onto path:" do
    root = PluginSpecHelper.tmp_path("kpg34-deploy-finalize")

    result = PluginSpecHelper.run("deploy_helper", {
      "mode"                => "0644",
      "owner"               => "root",
      "path"                => root,
      "releases_path"       => "zilrji",
      "shared_path"         => "/tmp/kpg34-no-such-shared",
      "state"               => "finalize",
      "unfinished_filename" => "wppgti",
      "release"             => "ljthig",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: [Errno 2] No such file or directory: " \
      "'#{root}/zilrji/ljthig' -> '#{root}/current'")
  end

  it "fails with real's dangling-source wording when current points elsewhere" do
    root = PluginSpecHelper.tmp_path("kpg34-deploy-dangling")
    Dir.mkdir_p(File.join(root, "releases", "old"))
    File.symlink(File.join(root, "releases", "old"), File.join(root, "current"))

    result = PluginSpecHelper.run("deploy_helper", {
      "path"          => root,
      "releases_path" => "releases",
      "state"         => "finalize",
      "release"       => "never-created",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the symlink target #{root}/releases/never-created doesn't exists")
  end

  it "is idempotent when current already points at the release" do
    root = PluginSpecHelper.tmp_path("kpg34-deploy-idem")
    Dir.mkdir_p(File.join(root, "releases", "r1"))
    File.symlink(File.join(root, "releases", "r1"), File.join(root, "current"))

    result = PluginSpecHelper.run("deploy_helper", {
      "path"          => root,
      "releases_path" => "releases",
      "state"         => "finalize",
      "release"       => "r1",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
  end
end

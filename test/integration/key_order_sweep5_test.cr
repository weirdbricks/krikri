require "../minitest_helper"
require "file_utils"

# Registered-result key orders for the modprobe/filesystem/pam_limits/
# pamd/seboolean/sefcontext/seport/iptables/apt_key/apt_repository/
# deb822_repository/package/yum/dnf/dnf5/rpm_key/yum_repository/
# htpasswd/make/script/expect/npm/gem plugins, pinned to the orders
# live-verified against real ansible-core 2.19.11 by registering each
# module's result and dumping `{{ r | to_json }}` (see
# key_order_sweep_test.cr for the general method; the -v dump sorts
# alphabetically, so the order is only observable programmatically).
#
# The pins cover the keys krikri emits, in real's relative order: real's
# registered result additionally carries controller-appended
# ansible_facts (interpreter discovery) and backfilled failed: false /
# warnings after the module dict, which krikri's module wire omits.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump5.json")
  playbook = File.tempname("key-order-sweep5", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def unique_tmp(*parts : String) : String
  PluginSpecHelper.tmp_path("#{parts.join("-")}-#{Random::Secure.hex(4)}")
end

describe "modprobe plugin result key order (sweep5)" do
  # Only the already-loaded success path is testable unprivileged (a
  # real load/unload needs root); every success exit goes through real
  # modprobe.py's single `module.exit_json(**modprobe.result)` with the
  # fixed-shape `result` property dict, so the pin covers them all.
  it "serializes an already-loaded module as changed-name-params-state (real: changed, name, params, state)" do
    loaded = File.read("/proc/modules").each_line.map { |line| line.split.first? }.to_a.compact.first?
    skip "no loaded modules visible in /proc/modules" unless loaded

    result = PluginSpecHelper.run("modprobe", {"name" => loaded, "state" => "present"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["name"].as_s.must_equal(loaded)
    result["params"].as_s.must_equal("")
    result["state"].as_s.must_equal("present")
    result.as_h.keys.must_equal(["changed", "name", "params", "state"])
  end
end

describe "filesystem plugin result key order" do
  # Real filesystem.py's success exits are exit_json(changed=changed)
  # with no msg key (create/already-same-fs/wipefs/absent-no-fs), and
  # state=absent on a missing dev exits exit_json(msg=msg) whose module
  # dict carries only msg before the controller-backfilled changed.
  # All verified against a file-backed fake device (mkfs.ext4 accepts a
  # regular file), live 2.19.11.
  it "serializes a fresh create as just changed (real: changed)" do
    dev = unique_tmp("fs-dev")
    File.write(dev, "")
    File.open(dev, "w") { |file| file.truncate(20 * 1024 * 1024) }

    result = PluginSpecHelper.run("filesystem", {"dev" => dev, "fstype" => "ext4", "state" => "present"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed"])
  end

  it "serializes an already-correct fs as just changed (real: changed)" do
    dev = unique_tmp("fs-dev")
    File.write(dev, "")
    File.open(dev, "w") { |file| file.truncate(20 * 1024 * 1024) }
    PluginSpecHelper.run("filesystem", {"dev" => dev, "fstype" => "ext4", "state" => "present"})

    result = PluginSpecHelper.run("filesystem", {"dev" => dev, "fstype" => "ext4", "state" => "present"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed"])
  end

  it "serializes state=absent without an fs as just changed (real: changed)" do
    dev = unique_tmp("fs-dev")
    File.write(dev, "")

    result = PluginSpecHelper.run("filesystem", {"dev" => dev, "state" => "absent"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed"])
  end

  it "serializes state=absent on a missing dev as msg-then-changed (real: msg, changed)" do
    dev = unique_tmp("fs-missing")

    result = PluginSpecHelper.run("filesystem", {"dev" => dev, "state" => "absent"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["msg"].as_s.includes?("not found").must_equal(true)
    result.as_h.keys.must_equal(["msg", "changed"])
  end
end

describe "pam_limits plugin result key order" do
  # Real pam_limits.py's res_args dict is {changed, msg, diff} with
  # backup_file appended only when a backup was taken - live-verified
  # 2.19.11 against a temp dest (add / already-set / backup /
  # check-mode all share the shape).
  def pam_limits_result(content : String, params : Hash(String, String))
    dest = unique_tmp("limits.conf")
    File.write(dest, content)
    PluginSpecHelper.run("pam_limits", {"dest" => dest}.merge(params))
  end

  it "serializes a new limit as changed-msg-diff (real: changed, msg, diff)" do
    result = pam_limits_result("", {
      "domain" => "krlim", "limit_type" => "soft", "limit_item" => "nofile", "value" => "1000",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("krlim\tsoft\tnofile\t1000\n")
    result["backup_file"]?.must_be_nil
    result.as_h.keys.must_equal(["changed", "msg", "diff"])
  end

  it "serializes an already-set limit as changed-msg-diff (real: changed, msg, diff)" do
    result = pam_limits_result("krlim\tsoft\tnofile\t1000\n", {
      "domain" => "krlim", "limit_type" => "soft", "limit_item" => "nofile", "value" => "1000",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "msg", "diff"])
  end

  it "serializes a backup-taking change with backup_file after diff (real: changed, msg, diff, backup_file)" do
    result = pam_limits_result("krlim\tsoft\tnofile\t1000\n", {
      "domain" => "krlim", "limit_type" => "soft", "limit_item" => "nofile", "value" => "2000",
      "backup" => "yes",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["backup_file"].as_s.wont_be_empty
    result.as_h.keys.must_equal(["changed", "msg", "diff", "backup_file"])
  end

  it "serializes a check-mode change as changed-msg-diff without backup_file (real: changed, msg, diff)" do
    result = pam_limits_result("krlim\tsoft\tnofile\t1000\n", {
      "domain" => "krlim", "limit_type" => "soft", "limit_item" => "nofile", "value" => "3000",
      "_ansible_check_mode" => "true",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["backup_file"]?.must_be_nil
    result.as_h.keys.must_equal(["changed", "msg", "diff"])
  end
end

describe "pamd plugin result key order" do
  # Real pamd's success result is {changed, change_count, backupdest}
  # with backupdest ALWAYS present (empty string when no backup) and no
  # msg key - live-verified 2.19.11 against a temp path dir (updated
  # change + idempotent re-run).
  it "serializes a rule update as changed-change_count-backupdest (real: changed, change_count, backupdest)" do
    dir = unique_tmp("pamdir")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "krservice"), "auth required pam_unix.so\naccount required pam_unix.so\n")

    result = PluginSpecHelper.run("pamd", {
      "name" => "krservice", "path" => dir, "type" => "auth", "control" => "required",
      "module_path" => "pam_unix.so", "module_arguments" => "nullok", "state" => "updated",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["change_count"].as_i.must_equal(1)
    result["backupdest"].as_s.must_equal("")
    result.as_h.keys.must_equal(["changed", "change_count", "backupdest"])
  end

  it "serializes an idempotent re-run as changed-change_count-backupdest (real: changed, change_count, backupdest)" do
    dir = unique_tmp("pamdir")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "krservice"), "auth required pam_unix.so nullok\naccount required pam_unix.so\n")

    result = PluginSpecHelper.run("pamd", {
      "name" => "krservice", "path" => dir, "type" => "auth", "control" => "required",
      "module_path" => "pam_unix.so", "module_arguments" => "nullok", "state" => "updated",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["change_count"].as_i.must_equal(0)
    result.as_h.keys.must_equal(["changed", "change_count", "backupdest"])
  end
end

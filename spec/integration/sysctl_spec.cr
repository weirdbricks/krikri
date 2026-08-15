require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "sysctl")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def fresh_conf(name : String, seed : String = "") : String
  path = File.join(TMP_DIR, name)
  File.write(path, seed)
  path
end

describe "sysctl plugin" do
  it "updates an existing key in place, preserving comments and other lines" do
    conf = fresh_conf("update.conf", "# custom sysctl\nnet.ipv4.ip_forward=0\n")

    result = PluginSpecHelper.run("sysctl", {
      "name" => "net.ipv4.ip_forward", "value" => "1", "sysctl_file" => conf, "reload" => "false",
    })

    result["changed"].as_bool.should be_true
    File.read(conf).should eq("# custom sysctl\nnet.ipv4.ip_forward=1\n")
  end

  it "reports changed: false on an idempotent rerun" do
    conf = fresh_conf("idempotent.conf")
    params = {"name" => "net.ipv4.ip_forward", "value" => "1", "sysctl_file" => conf, "reload" => "false"}
    PluginSpecHelper.run("sysctl", params)

    result = PluginSpecHelper.run("sysctl", params)

    result["changed"].as_bool.should be_false
  end

  it "appends a new key that isn't present yet" do
    conf = fresh_conf("append.conf", "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "value" => "10", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.should be_true
    File.read(conf).should eq("net.ipv4.ip_forward=1\nvm.swappiness=10\n")
  end

  it "removes the key entirely with state: absent" do
    conf = fresh_conf("remove.conf", "net.ipv4.ip_forward=1\nvm.swappiness=10\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "state" => "absent", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.should be_true
    File.read(conf).should eq("net.ipv4.ip_forward=1\n")
  end

  it "reports changed: false removing a key that isn't present" do
    conf = fresh_conf("remove-noop.conf", "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "never.there", "state" => "absent", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.should be_false
  end

  it "creates the file from scratch when it doesn't exist yet" do
    conf = File.join(TMP_DIR, "new-file.conf")
    File.delete(conf) if File.exists?(conf)

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "value" => "5", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.should be_true
    File.read(conf).should eq("vm.swappiness=5\n")
  end

  it "does not write anything in check mode" do
    conf = fresh_conf("check-mode.conf", "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {
      "name" => "vm.swappiness", "value" => "10", "sysctl_file" => conf, "reload" => "false", "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.read(conf).should eq("net.ipv4.ip_forward=1\n")
  end

  it "fails the task when sysctl_set: true and the live `sysctl -w` call itself fails" do
    # Proactive audit fix (same bug shape as apt_repository.cr's own
    # update_cache failure this round, found in a different plugin):
    # apply_kernel_value's `sysctl -w` result used to be discarded
    # entirely - execute() unconditionally returned failed: false
    # regardless of whether the live kernel-parameter set actually
    # succeeded. Real ansible.posix.sysctl fails the task when this
    # fails, unless ignoreerrors: is set. Using a bogus dotted name
    # here (real `sysctl -w` genuinely fails on any Linux host for a
    # name with no matching /proc/sys/ path - verified directly against
    # the real `sysctl` binary, not assumed) - no real kernel parameter
    # is touched either way.
    conf = fresh_conf("sysctl-set-fail.conf")
    bogus_name = "this.is.not.a.real.sysctl.key.crystal_ansible_spec"

    result = PluginSpecHelper.run("sysctl", {
      "name"         => bogus_name,
      "value"        => "1",
      "sysctl_file"  => conf,
      "sysctl_set"   => "true",
      "reload"       => "false",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain(bogus_name)
  end

  it "does not fail on a live sysctl -w failure when ignoreerrors: true" do
    conf = fresh_conf("sysctl-set-ignore.conf")
    bogus_name = "this.is.not.a.real.sysctl.key.crystal_ansible_spec"

    result = PluginSpecHelper.run("sysctl", {
      "name"         => bogus_name,
      "value"        => "1",
      "sysctl_file"  => conf,
      "sysctl_set"   => "true",
      "ignoreerrors" => "true",
      "reload"       => "false",
    })

    result["failed"].as_bool.should be_false
  end

  it "fails with a clear message when value is missing for state: present" do
    conf = fresh_conf("missing-value.conf")

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "sysctl_file" => conf, "reload" => "false"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value")
  end

  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("sysctl", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name")
  end
end

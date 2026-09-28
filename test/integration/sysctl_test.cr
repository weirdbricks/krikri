require "../minitest_helper"
require "file_utils"

private def fresh_conf(name : String, seed : String = "") : String
  path = PluginSpecHelper.tmp_path(name)
  File.write(path, seed)
  path
end

describe "sysctl plugin" do
  it "updates an existing key in place, preserving comments and other lines" do
    conf = fresh_conf("update.conf", "# custom sysctl\nnet.ipv4.ip_forward=0\n")

    result = PluginSpecHelper.run("sysctl", {
      "name" => "net.ipv4.ip_forward", "value" => "1", "sysctl_file" => conf, "reload" => "false",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("# custom sysctl\nnet.ipv4.ip_forward=1\n")
  end

  it "reports changed: false on an idempotent rerun" do
    conf = fresh_conf("idempotent.conf")
    params = {"name" => "net.ipv4.ip_forward", "value" => "1", "sysctl_file" => conf, "reload" => "false"}
    PluginSpecHelper.run("sysctl", params)

    result = PluginSpecHelper.run("sysctl", params)

    result["changed"].as_bool.must_equal(false)
  end

  it "appends a new key that isn't present yet" do
    conf = fresh_conf("append.conf", "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "value" => "10", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("net.ipv4.ip_forward=1\nvm.swappiness=10\n")
  end

  it "removes the key entirely with state: absent" do
    conf = fresh_conf("remove.conf", "net.ipv4.ip_forward=1\nvm.swappiness=10\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "state" => "absent", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("net.ipv4.ip_forward=1\n")
  end

  it "reports changed: false removing a key that isn't present" do
    conf = fresh_conf("remove-noop.conf", "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "never.there", "state" => "absent", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.must_equal(false)
  end

  it "creates the file from scratch when it doesn't exist yet" do
    conf = PluginSpecHelper.tmp_path("new-file.conf")
    File.delete(conf) if File.exists?(conf)

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "value" => "5", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("vm.swappiness=5\n")
  end

  it "does not write anything in check mode" do
    conf = fresh_conf("check-mode.conf", "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {
      "name" => "vm.swappiness", "value" => "10", "sysctl_file" => conf, "reload" => "false", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("net.ipv4.ip_forward=1\n")
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
      "name"        => bogus_name,
      "value"       => "1",
      "sysctl_file" => conf,
      "sysctl_set"  => "true",
      "reload"      => "false",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(bogus_name)
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "applies a space-separated value via sysctl_set without splitting it into two shell words" do
    # apply_kernel_value used to build `sysctl -w name=value` with value
    # unquoted - a space-separated value (net.ipv4.ip_local_port_range's
    # own real shape: "32768 65535") split into two shell words, so
    # sysctl set only the first token and then failed on the second as a
    # bogus bare key, failing the whole task where real
    # ansible.posix.sysctl's own quoted write succeeds. Found via
    # juju4.harden_sysctl, round 60128. Re-applies the key's own CURRENT
    # live value (read directly from /proc/sys first) so this is a
    # verified no-op against the real kernel, not a mutation the spec
    # needs to undo.
    key_path = "/proc/sys/net/ipv4/ip_local_port_range"
    skip "no #{key_path} on this host" unless File.exists?(key_path)
    skip "sysctl -w needs root" unless PluginSpecHelper.running_as_root?
    current_value = File.read(key_path).strip.split(/\s+/).join(" ")

    conf = fresh_conf("space-value.conf")
    result = PluginSpecHelper.run("sysctl", {
      "name" => "net.ipv4.ip_local_port_range", "value" => current_value,
      "sysctl_file" => conf, "sysctl_set" => "true", "reload" => "false",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "normalizes boolean values to 1/0 like real _parse_value, and stays idempotent across equivalent booleans" do
    # Real _parse_value turns y/yes/on/1/true (any case) into "1" and
    # n/no/off/0/false into "0" before comparing or writing, so value:
    # yes then value: true is a no-op rerun, not a second change.
    conf = fresh_conf("bool-normalize.conf")

    result = PluginSpecHelper.run("sysctl", {"name" => "net.ipv4.krikri_spec_bool", "value" => "yes", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("net.ipv4.krikri_spec_bool=1\n")

    rerun = PluginSpecHelper.run("sysctl", {"name" => "net.ipv4.krikri_spec_bool", "value" => "true", "sysctl_file" => conf, "reload" => "false"})

    rerun["changed"].as_bool.must_equal(false)
    File.read(conf).must_equal("net.ipv4.krikri_spec_bool=1\n")
  end

  it "rewrites a loosely-spaced existing key line in real fix_lines form (key=value, stripped)" do
    # Real fix_lines re-emits every parsed key as "key=value" with both
    # sides stripped, so pre-existing "key = value" spacing is
    # normalized on the next write of the file.
    conf = fresh_conf("spacing.conf", "net.ipv4.ip_forward = 0\n")

    result = PluginSpecHelper.run("sysctl", {"name" => "net.ipv4.ip_forward", "value" => "1", "sysctl_file" => conf, "reload" => "false"})

    result["changed"].as_bool.must_equal(true)
    File.read(conf).must_equal("net.ipv4.ip_forward=1\n")
  end

  it "fails with a clear message when value is missing for state: present" do
    conf = fresh_conf("missing-value.conf")

    result = PluginSpecHelper.run("sysctl", {"name" => "vm.swappiness", "sysctl_file" => conf, "reload" => "false"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value")
  end

  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("sysctl", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("name")
  end
end

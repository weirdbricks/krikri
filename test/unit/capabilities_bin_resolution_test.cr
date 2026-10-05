require "../minitest_helper"

# Pins plugins/capabilities.cr's module-init ordering and its
# operator-error wording against real community.general.capabilities
# 2.19.11: CapabilitiesModule.__init__ resolves BOTH helper binaries
# through module.get_bin_path(required=True) BEFORE it parses the
# capability argument, so a host without libcap2-bin reports the missing
# getcap even when the capability string is malformed - and Ansible's
# operator error interpolates the OPS TUPLE, so it prints with Python
# repr punctuation ("one of: ('=', '-', '+')").
#
# Live-diffed vs ansible-playbook through the kpg32 generator sweep
# (15/15 capabilities playbooks) and a local ansible_connection=local
# repro on a host that does have getcap/setcap installed.
describe "capabilities plugin binary resolution" do
  # getcap/setcap live in /sbin or /usr/sbin on most hosts, which
  # module_utils' get_bin_path searches even when PATH does not list it
  # - so a test host can be perfectly capable while Process.find_executable
  # (which only reads PATH) finds nothing.
  def cap_binary_available?(name : String) : Bool
    paths = (ENV["PATH"]? || "").split(':')
    {"/sbin", "/usr/sbin", "/usr/local/sbin"}.each do |dir|
      paths << dir if !paths.includes?(dir) && Dir.exists?(dir)
    end
    paths.any? do |dir|
      candidate = File.join(dir, name)
      File.exists?(candidate) && !File.directory?(candidate) && File::Info.executable?(candidate)
    end
  end

  it "reports the operator error with Ansible's tuple repr" do
    skip "host has no getcap/setcap, so Ansible fails on the binary lookup first" unless cap_binary_available?("getcap") && cap_binary_available?("setcap")

    path = PluginSpecHelper.tmp_path("krikri-cap-op")
    File.write(path, "")

    result = PluginSpecHelper.run("capabilities", {"path" => path, "capability" => "cap_net_raw"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Couldn't find operator (one of: ('=', '-', '+'))")
  end

  it "reports the operator error even for a capability that only misses its operator in present state" do
    skip "host has no getcap/setcap, so Ansible fails on the binary lookup first" unless cap_binary_available?("getcap") && cap_binary_available?("setcap")

    path = PluginSpecHelper.tmp_path("krikri-cap-op2")
    File.write(path, "")

    result = PluginSpecHelper.run("capabilities",
      {"path" => path, "capability" => "CAP_NET_RAW", "state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Couldn't find operator (one of: ('=', '-', '+'))")
  end

  it "validates the state choice before resolving the helper binaries" do
    # Argument-spec validation happens in AnsibleModule.__init__, i.e.
    # strictly before CapabilitiesModule's get_bin_path calls, so this
    # wording wins over any binary lookup on every host.
    path = PluginSpecHelper.tmp_path("krikri-cap-state")
    File.write(path, "")

    result = PluginSpecHelper.run("capabilities",
      {"path" => path, "capability" => "cap_net_raw", "state" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, got: banana")
  end

  it "leaves a capability that already holds the wanted entry unchanged" do
    skip "host has no getcap/setcap, so Ansible fails on the binary lookup first" unless cap_binary_available?("getcap") && cap_binary_available?("setcap")

    path = PluginSpecHelper.tmp_path("krikri-cap-absent")
    File.write(path, "")

    # The scratch file has no capabilities at all, so the absent branch
    # finds nothing to remove: Ansible's own unchanged exit, which carries
    # state and no msg.
    result = PluginSpecHelper.run("capabilities",
      {"path" => path, "capability" => "cap_net_raw", "state" => "absent"})

    result["failed"]?.try(&.as_bool).must_be_nil
    result["changed"].as_bool.must_equal(false)
    result["state"].as_s.must_equal("absent")
    result["msg"]?.try(&.as_s).must_be_nil
  end
end

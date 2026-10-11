require "../minitest_helper"

# These specs cover ansible.posix.firewalld_info (added for the
# deekayen.ping round 5460373: the module didn't exist here at all, the
# "read the zone settings" task was silently skipped, and the role's
# later `ping_firewalld_info.firewalld_info.zones[...].icmp_block_inversion`
# dereference died with "object of type 'dict' has no attribute
# 'firewalld_info'" while ansible-playbook ran clean).
#
# The module's own backend is the python-firewall D-Bus client, so the
# dev-sandbox cases (no python-dbus/python-firewall installed, see
# plugins/firewalld.cr's own doc comment) only exercise the import gate;
# the full result shape is exercised wherever a running firewalld and its
# python bindings exist (skipped elsewhere), and was verified live
# against a firewalld 2.4.4 container + the real module under
# ansible-core (see git log).
private def firewalld_python_stack? : Bool
  python = Process.find_executable("python3") || Process.find_executable("python")
  return false unless python
  Process.run(python, {"-c", "import dbus, firewall.client"},
    output: Process::Redirect::Close, error: Process::Redirect::Close).success?
end

private def dbus_python_module? : Bool
  python = Process.find_executable("python3") || Process.find_executable("python")
  return false unless python
  Process.run(python, {"-c", "import dbus"},
    output: Process::Redirect::Close, error: Process::Redirect::Close).success?
end

private def firewalld_daemon_running? : Bool
  io = IO::Memory.new
  status = Process.run("firewall-cmd", {"--state"}, output: io, error: Process::Redirect::Close)
  status.success? && io.to_s.strip == "running"
rescue
  false
end

describe "firewalld_info plugin" do
  it "fails with Ansible's python-dbus missing_required_lib message when the python stack is absent" do
    result = PluginSpecHelper.run("firewalld_info", {"zones" => %(["public"])})

    if firewalld_python_stack?
      # With the stack installed the gate passes and the run proceeds to
      # the daemon interaction (or its DBusException failure) - neither
      # import-gate message may appear on that path.
      msg = result["msg"]?.try(&.as_s) || ""
      msg.wont_match(/Failed to import the required Python library \(python-dbus\)/)
      msg.wont_match(/Failed to import the required Python library \(firewall\)/)
    else
      result["failed"].as_bool.must_equal(true)
      # The module's own gate order: python-dbus first, python-firewall
      # second - so a target with dbus but no firewall bindings reports
      # the firewall message (this dev sandbox's own case).
      expected = dbus_python_module? ? "firewall" : "python-dbus"
      result["msg"].as_s.must_match(/\AFailed to import the required Python library \(#{expected}\) on /)
    end
  end

  it "gathers the zone dict with Ansible's exact result shape and key order" do
    skip "no firewalld python stack on this host" unless firewalld_python_stack?
    skip "no running firewalld on this host" unless firewalld_daemon_running?

    default_zone = `firewall-cmd --get-default-zone`.strip
    result = PluginSpecHelper.run("firewalld_info", {"zones" => %(["#{default_zone}"])})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"]?.must_be_nil
    result["active_zones"].as_bool.must_equal(false)
    result["collected_zones"].as_a.must_equal([JSON::Any.new(default_zone)])
    result["undefined_zones"].as_a.must_equal([] of JSON::Any)

    info = result["firewalld_info"].as_h
    info["version"].as_s?.wont_be_nil
    info["default_zone"].as_s.must_equal(default_zone)
    zone = info["zones"].as_h[default_zone].as_h
    zone.keys.must_equal([
      "target", "icmp_block_inversion", "interfaces", "sources", "services",
      "ports", "protocols", "masquerade", "forward_ports", "source_ports",
      "icmp_blocks", "rich_rules", "forward",
    ])
    zone["target"].as_s?.wont_be_nil
    ["icmp_block_inversion", "masquerade", "forward"].each do |key|
      zone[key].as_bool?.wont_be_nil
    end
    # Ports are [port, proto] pair lists, the module's own tuple shape.
    zone["ports"].as_a.each do |entry|
      entry.as_a.size.must_equal(2)
    end
    zone["forward_ports"].as_a.each do |entry|
      entry.as_a.size.must_equal(4)
    end
  end

  it "moves an unresolvable zone into undefined_zones with Ansible's warning text" do
    skip "no firewalld python stack on this host" unless firewalld_python_stack?
    skip "no running firewalld on this host" unless firewalld_daemon_running?

    result = PluginSpecHelper.run("firewalld_info", {
      "zones" => %(["public", "krikri-spec-undefined-zone"]),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["collected_zones"].as_a.must_equal([JSON::Any.new("public")])
    result["undefined_zones"].as_a.must_equal([JSON::Any.new("krikri-spec-undefined-zone")])
    result["warnings"].as_a.size.must_equal(1)
    result["warnings"].as_a[0].as_s.must_equal(
      "Please note: zone:(krikri-spec-undefined-zone) have been ignored in the gathering process.")
  end

  it "collects the active zones when active_zones: true is given" do
    skip "no firewalld python stack on this host" unless firewalld_python_stack?
    skip "no running firewalld on this host" unless firewalld_daemon_running?

    result = PluginSpecHelper.run("firewalld_info", {"active_zones" => "true"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["active_zones"].as_bool.must_equal(true)
    active = `firewall-cmd --get-active-zones`.strip.lines.map(&.split(" ").first)
    result["collected_zones"].as_a.map(&.as_s).must_equal(active)
  end

  it "emits the module's own result key order (no msg key on success)" do
    skip "no firewalld python stack on this host" unless firewalld_python_stack?
    skip "no running firewalld on this host" unless firewalld_daemon_running?

    result = PluginSpecHelper.run("firewalld_info", {"zones" => %(["public"])})
    keys = result.as_h.keys
    keys.first(6).must_equal([
      "changed", "active_zones", "collected_zones", "undefined_zones",
      "warnings", "firewalld_info",
    ])
  end
end

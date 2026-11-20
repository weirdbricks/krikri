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

# A python-dbus/python-firewall stand-in so the ignored-zones path runs
# without a firewalld daemon: two real zones exist, everything else the
# probe reads is empty.
private def firewalld_zone_stub : String
  stub = PluginSpecHelper.tmp_path("firewalld-stub")
  Dir.mkdir_p(File.join(stub, "dbus"))
  Dir.mkdir_p(File.join(stub, "firewall"))
  File.write(File.join(stub, "dbus", "__init__.py"), [
    "class exceptions:",
    "    class DBusException(Exception):",
    "        pass",
    "",
  ].join("\n"))
  File.write(File.join(stub, "firewall", "__init__.py"), "")
  File.write(File.join(stub, "firewall", "config.py"), "VERSION = \"2.4.4\"\n")
  File.write(File.join(stub, "firewall", "client.py"), [
    "class _Settings:",
    "    def getTarget(self): return \"default\"",
    "    def getIcmpBlockInversion(self): return False",
    "    def getInterfaces(self): return []",
    "    def getSources(self): return []",
    "    def getServices(self): return []",
    "    def getPorts(self): return []",
    "    def getProtocols(self): return []",
    "    def getMasquerade(self): return False",
    "    def getForwardPorts(self): return []",
    "    def getSourcePorts(self): return []",
    "    def getIcmpBlocks(self): return []",
    "    def getRichRules(self): return []",
    "    def getForward(self): return False",
    "",
    "",
    "class FirewallClient:",
    "    def getDefaultZone(self): return \"public\"",
    "    def getZones(self): return [\"public\", \"trusted\"]",
    "    def getActiveZones(self): return {\"public\": []}",
    "    def getZoneSettings(self, zone): return _Settings()",
    "",
  ].join("\n"))
  stub
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

  # ansible.posix 2.2.0 moved the note from a ','.join in exit_json's
  # `warnings` kwarg to module.warn(... % ", ".join(...)). Real derives the
  # list from a Python set (hash-randomized per module process), so krikri
  # keeps the specified order and only the separator follows the release.
  it "joins several ignored zones with the resolved release's separator" do
    python = Process.find_executable("python3") || Process.find_executable("python")
    skip "no python interpreter on this host" unless python

    stub = firewalld_zone_stub

    zones = %(["krikri-spec-undefined-a", "krikri-spec-undefined-b", "krikri-spec-undefined-c"])
    expected = %w[krikri-spec-undefined-a krikri-spec-undefined-b krikri-spec-undefined-c]

    legacy = PluginSpecHelper.run("firewalld_info", {"zones" => zones},
      env: {"PYTHONPATH" => stub}, collection_version: "2.1.0")
    legacy["undefined_zones"].as_a.map(&.as_s).must_equal(expected)
    legacy_note = legacy["warnings"].as_a[0].as_s
    legacy_note.match!(/zone:\((.*)\) have been ignored/)[1].split(",").must_equal(expected)

    modern = PluginSpecHelper.run("firewalld_info", {"zones" => zones},
      env: {"PYTHONPATH" => stub}, collection_version: "2.2.2")
    modern["undefined_zones"].as_a.map(&.as_s).must_equal(expected)
    modern_note = modern["warnings"].as_a[0].as_s
    modern_note.match!(/zone:\((.*)\) have been ignored/)[1].split(", ").must_equal(expected)
  end

  # Issue #1628's kpg case: real builds the ignored list as
  # list(set(specified) - set(collected)), so string-hash randomization
  # flips the order per module process (five real runs in one container
  # alternated between both orders). The declared order is one of real's
  # possible orders; sorting would be no better, so it is pinned here to
  # keep a later "parity fix" from sorting it.
  it "keeps the declared order of several ignored zones" do
    stub = firewalld_zone_stub

    result = PluginSpecHelper.run("firewalld_info", {"zones" => %(["wmnfiv", "lecefn"])},
      env: {"PYTHONPATH" => stub}, collection_version: "2.1.0")

    result["undefined_zones"].as_a.map(&.as_s).must_equal(%w[wmnfiv lecefn])
    result["warnings"].as_a[0].as_s.must_equal(
      "Please note: zone:(wmnfiv,lecefn) have been ignored in the gathering process.")
  end

  # Same release split, but over the host's own firewalld stack rather than
  # a stub, and asserting the whole note - the kpg repro for issue #1299
  # only caught it because a real 2.2.x collection was installed.
  it "joins the ignored-zones note with the resolved release line's separator" do
    skip "no firewalld python stack on this host" unless firewalld_python_stack?
    skip "no running firewalld on this host" unless firewalld_daemon_running?

    zones = %(["krikri-spec-undefined-a", "krikri-spec-undefined-b"])

    legacy = PluginSpecHelper.run("firewalld_info", {"zones" => zones}, collection_version: "2.1.0")
    legacy["warnings"].as_a[0].as_s.must_equal(
      "Please note: zone:(krikri-spec-undefined-a,krikri-spec-undefined-b) have been ignored in the gathering process.")

    modern = PluginSpecHelper.run("firewalld_info", {"zones" => zones}, collection_version: "2.2.2")
    modern["warnings"].as_a[0].as_s.must_equal(
      "Please note: zone:(krikri-spec-undefined-a, krikri-spec-undefined-b) have been ignored in the gathering process.")
  end

  # The exit_json `warnings` deprecation models the 2.1.x module line,
  # whose result passes `warnings` to exit_json - ansible.posix 2.2.x
  # triggers no deprecation at all (issue #1060's release split, the
  # same gate mount.cr's identical helper takes). Needs the full success
  # path, so it lives wherever a running firewalld exists, like the
  # shape specs above.
  it "gates the exit_json warnings deprecation on the resolved collection release" do
    skip "no firewalld python stack on this host" unless firewalld_python_stack?
    skip "no running firewalld on this host" unless firewalld_daemon_running?

    default_zone = `firewall-cmd --get-default-zone`.strip

    legacy = PluginSpecHelper.run("firewalld_info", {"zones" => %(["#{default_zone}"])}, collection_version: "2.1.0")
    falsey?(legacy["failed"]?.try(&.as_bool)).must_equal(true)
    # The import deprecation rides ahead of the exit_json one (the
    # imports happen before the module body), same as mount's order.
    legacy["deprecations"].as_a.map(&.["msg"].as_s).must_equal([
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated.",
      "Passing `warnings` to `exit_json` or `fail_json` is deprecated.",
    ])
    legacy["_ansible_core_deprecations"].as_a.size.must_equal(2)

    modern = PluginSpecHelper.run("firewalld_info", {"zones" => %(["#{default_zone}"])}, collection_version: "2.2.2")
    falsey?(modern["failed"]?.try(&.as_bool)).must_equal(true)
    modern.as_h.has_key?("deprecations").must_equal(false)
    modern.as_h.has_key?("_ansible_core_deprecations").must_equal(false)
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

  # With no system-bus daemon listening, firewalld's FirewallClient wraps the
  # D-Bus failure in firewall.errors.FirewallError, which the module's own
  # try block does not catch - real ends the task as an uncaught module
  # exception, not with the module's "Unable to gather firewalld settings"
  # fail_json. The crash result is built from the exception alone, so the
  # module's collected import deprecation does not ride along either
  # (live-verified vs 2.21.6 against this exact stub stack, issue #1627).
  it "reports a client-construction crash the way Ansible's module wrapper does" do
    stub = PluginSpecHelper.tmp_path("firewalld-crash-stub")
    Dir.mkdir_p(File.join(stub, "dbus"))
    Dir.mkdir_p(File.join(stub, "firewall"))
    File.write(File.join(stub, "dbus", "__init__.py"), [
      "class exceptions:",
      "    class DBusException(Exception):",
      "        pass",
      "",
    ].join("\n"))
    File.write(File.join(stub, "firewall", "__init__.py"), "")
    File.write(File.join(stub, "firewall", "config.py"), "VERSION = \"2.4.4\"\n")
    File.write(File.join(stub, "firewall", "client.py"), [
      "import dbus",
      "",
      "",
      "class FirewallError(Exception):",
      "    pass",
      "",
      "",
      "def _impl(func):",
      "    def wrapper(*args, **kwargs):",
      "        try:",
      "            return func(*args, **kwargs)",
      "        except dbus.exceptions.DBusException:",
      "            raise FirewallError(\"DBUS_ERROR: Failed to connect to socket \"",
      "                                \"/run/dbus/system_bus_socket: No such file or directory\")",
      "",
      "    return wrapper",
      "",
      "",
      "class FirewallClient:",
      "    @_impl",
      "    def __init__(self):",
      "        raise dbus.exceptions.DBusException(",
      "            \"org.freedesktop.DBus.Error.FileNotFound: Failed to connect to socket \"",
      "            \"/run/dbus/system_bus_socket: No such file or directory\")",
      "",
    ].join("\n"))

    result = PluginSpecHelper.run("firewalld_info", {"zones" => %(["public"])},
      env: {"PYTHONPATH" => stub})

    detail = "DBUS_ERROR: Failed to connect to socket /run/dbus/system_bus_socket: No such file or directory"
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: #{detail}")
    result["_ansible_error_detail"].as_s.must_equal(detail)
    result["_ansible_crash_context"].as_bool.must_equal(true)
    result.as_h.has_key?("deprecations").must_equal(false)
    result.as_h.has_key?("_ansible_core_deprecations").must_equal(false)
  end
end

private FIREWALLD_ORDER_PROJECT_ROOT = File.expand_path("../..", __DIR__)
private FIREWALLD_ORDER_BINARY       = File.join(FIREWALLD_ORDER_PROJECT_ROOT, "bin", "krikri-playbook")
private FIREWALLD_ORDER_INVENTORY    = File.join(FIREWALLD_ORDER_PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# A result can carry module warnings AND deprecations at once, and real's
# callback (_handle_warnings) walks the result's `warnings` list first and
# its `deprecations` list second. firewalld_info 2.1.x is exactly that
# shape: the ignored-zones note rides `warnings`, while the deprecated
# `_text` import and the `warnings`-kwarg exit_json deprecation ride
# `deprecations`. The stub D-Bus/firewall stack keeps the runnable shape
# independent of a running firewalld daemon - the expected order is what
# ansible-playbook 2.21.6 + ansible.posix 2.1.0 prints for the same stub.
describe "firewalld_info's warnings and deprecations display order" do
  it "prints the ignored-zones warning before the module's deprecations (issue #1627)" do
    stub = PluginSpecHelper.tmp_path("firewalld-order-stub")
    Dir.mkdir_p(File.join(stub, "dbus"))
    Dir.mkdir_p(File.join(stub, "firewall"))
    File.write(File.join(stub, "dbus", "__init__.py"), [
      "class exceptions:",
      "    class DBusException(Exception):",
      "        pass",
      "",
    ].join("\n"))
    File.write(File.join(stub, "firewall", "__init__.py"), "")
    File.write(File.join(stub, "firewall", "config.py"), "VERSION = \"2.4.4\"\n")
    File.write(File.join(stub, "firewall", "client.py"), [
      "class _Settings:",
      "    def getTarget(self): return \"default\"",
      "    def getIcmpBlockInversion(self): return False",
      "    def getInterfaces(self): return []",
      "    def getSources(self): return []",
      "    def getServices(self): return []",
      "    def getPorts(self): return []",
      "    def getProtocols(self): return []",
      "    def getMasquerade(self): return False",
      "    def getForwardPorts(self): return []",
      "    def getSourcePorts(self): return []",
      "    def getIcmpBlocks(self): return []",
      "    def getRichRules(self): return []",
      "    def getForward(self): return False",
      "",
      "",
      "class FirewallClient:",
      "    def getDefaultZone(self): return \"public\"",
      "    def getZones(self): return [\"public\", \"trusted\"]",
      "    def getActiveZones(self): return {\"public\": []}",
      "    def getZoneSettings(self, zone): return _Settings()",
      "",
    ].join("\n"))

    playbook = File.join(stub, "repro.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.posix.firewalld_info:
              zones:
                - wmnfiv
                - lecefn
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(FIREWALLD_ORDER_BINARY, ["-i", FIREWALLD_ORDER_INVENTORY, playbook],
      output: stdout, error: stderr, env: ENV.to_h.merge({"PYTHONPATH" => stub}))

    status.success?.must_equal(true)
    stdout.to_s.must_match(/ok=1\b/)

    note = "[WARNING]: Please note: zone:(wmnfiv,lecefn) have been ignored in the gathering process."
    hint = "[WARNING]: Deprecation warnings can be disabled"
    import_line = "[DEPRECATION WARNING]: Importing 'to_native' from 'ansible.module_utils._text' is deprecated."
    kwarg_line = "[DEPRECATION WARNING]: Passing `warnings` to `exit_json` or `fail_json` is deprecated."
    err = stderr.to_s
    err.must_include(note)
    err.must_include(import_line)
    err.must_include(kwarg_line)
    (err.index!(note) < err.index!(hint)).must_equal(true)
    (err.index!(hint) < err.index!(import_line)).must_equal(true)
    (err.index!(import_line) < err.index!(kwarg_line)).must_equal(true)
  end
end

require "../minitest_helper"

# These specs cover the plugin's own pre-flight validation, which
# returns before any real `firewall-offline-cmd` invocation - safe to run
# without firewalld installed (not available on the regular dev machine,
# see plugins/firewalld.cr's own doc comment).
#
# Real firewalld.py runs its python `firewall` library import gate
# (sanity_check) BEFORE all of this module-level validation, so on a
# host whose python cannot import the bindings real itself fails with
# missing_required_lib('firewall') + the version suffix - exactly what
# the plugin's own gate (kpg34) emits here. The expectations therefore
# branch on the library's availability: with it, the module-level
# wording below is what Ansible reports; without it, the import gate wins
# (live-verified against ansible-playbook 2.19.11 in both
# directions).
private def firewall_lib_importable? : Bool
  python = Process.find_executable("python3") || Process.find_executable("python")
  return false unless python
  Process.run(python, {"-c", "import firewall.config"},
    output: Process::Redirect::Close, error: Process::Redirect::Close).success?
end

describe "firewalld plugin" do
  it "rejects state: present for a non-target thing (matches Ansible's own validation)" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "present", "service" => "http",
      "offline" => "true", "permanent" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    if firewall_lib_importable?
      result["msg"].as_s.must_equal("absent and present state can only be used in zone level operations")
    else
      result["msg"].as_s.must_match(/\AFailed to import the required Python library \(firewall\) on /)
    end
  end

  it "rejects state: absent for port_forward (matches Ansible's own validation)" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "absent",
      "port_forward" => %([{"port": 80, "proto": "tcp", "toport": 8080}]),
      "offline" => "true", "permanent" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    if firewall_lib_importable?
      result["msg"].as_s.must_equal("absent and present state can only be used in zone level operations")
    else
      result["msg"].as_s.must_match(/\AFailed to import the required Python library \(firewall\) on /)
    end
  end

  it "still allows state: present/absent for target: (the real zone-level exception)" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "present", "target" => "ACCEPT",
      "offline" => "true", "permanent" => "true",
    })

    result["msg"]?.try(&.as_s).wont_equal("absent and present state can only be used in zone level operations")
  end

  # round900593 Thulium-Drake.firewalld: a bare `zone:` + `state:` task
  # (no target/service/port/anything) is Ansible's own
  # ZoneTransaction - a zone create/delete - and must not hit the
  # "zone level operations" rejection. The create runs in check mode so
  # the spec never writes a real /etc/firewalld/zones file on the dev
  # machine (this spec file stays validation-only, see its header).
  it "treats a bare zone: + state: present as a zone create, not a rejection" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "krikri-spec-uncreated-zone", "state" => "present",
      "offline" => "true", "permanent" => "true", "_ansible_check_mode" => "true",
    })

    if firewall_lib_importable?
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
    else
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_match(/\AFailed to import the required Python library \(firewall\) on /)
    end
  end

  it "treats a bare zone: + state: absent for a missing zone as an idempotent no-op" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "krikri-spec-uncreated-zone", "state" => "absent",
      "offline" => "true", "permanent" => "true",
    })

    if firewall_lib_importable?
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      falsey?(result["changed"]?.try(&.as_bool)).must_equal(true)
    else
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_match(/\AFailed to import the required Python library \(firewall\) on /)
    end
  end
end

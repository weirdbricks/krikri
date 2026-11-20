require "../minitest_helper"

# These specs cover the plugin's own pre-flight validation, which
# returns before any real `firewall-offline-cmd` invocation - safe to run
# without firewalld installed (not available on the regular dev machine,
# see plugins/firewalld.cr's own doc comment). The runtime-transaction
# specs at the bottom put a stub `firewall-cmd` (and a stub interpreter
# for the plugin's python-library gate) on the plugin's PATH, so no
# daemon is involved there either.
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

  # kpg 000022-multi-firewalld-happy: `icmp_block: ffttre` (a name no
  # icmptype XML defines) with no permanent/immediate flags defaults to
  # Ansible's Non-permanent (runtime) operation. Ansible's
  # IcmpBlockTransaction.get_enabled_immediate is a membership test over
  # the zone's whole icmp-block list (`icmp_block in
  # self.fw.getIcmpBlocks(zone)`), so the undefined name reads as "not
  # enabled" and in check mode Ansible exits changed=True. Probing with
  # `firewall-cmd --query-icmp-block=ffttre` instead validates the name
  # and fails without Ansible's context msg, so check mode failed and
  # real mode's msg lost the " Non-permanent operation" tail. The fake
  # firewall-cmd below is the live-verified shape (firewalld 2.3.1):
  # --query-icmp-block exits 107 with INVALID_ICMPTYPE, --list-icmp-blocks
  # still succeeds, and the add fails with the same error.
  private def firewalld_cli_stub(scratch : String) : {String, String, String}
    FileUtils.mkdir_p(scratch)
    log = File.join(scratch, "firewall-cmd.log")
    script = File.join(scratch, "firewall-cmd")
    File.write(script, <<-SH)
      #!/bin/sh
      echo "$*" >> "#{log}"
      case "$*" in
        *--state*) echo running ;;
        *--get-default-zone*) echo public ;;
        *--list-icmp-blocks*) : ;;
        *--add-icmp-block=*) echo "Error: INVALID_ICMPTYPE: ffttre" >&2; exit 107 ;;
        *) echo "unexpected firewall-cmd invocation: $*" >&2; exit 1 ;;
      esac
      SH
    File.chmod(script, 0o755)
    # The plugin's own firewall-library import gate runs BEFORE all of
    # this and probes the interpreter by NAME (INTERPRETER_FALLBACK's
    # first entry), so the stub must carry that name to win
    # Process.find_executable.
    python = File.join(scratch, "python3.13")
    File.write(python, "#!/bin/sh\nexit 0\n")
    File.chmod(python, 0o755)
    {log, script, python}
  end

  it "reports changed for an undefined icmp_block in check mode, like Ansible's list-membership probe" do
    scratch = PluginSpecHelper.tmp_path("firewalld-icmp-block-check")
    log, _script, _python = firewalld_cli_stub(scratch)

    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "enabled", "icmp_block" => "ffttre",
      "timeout" => "39", "_ansible_check_mode" => "true",
      "_environment" => {"PATH" => "#{scratch}:/usr/bin:/bin"}.to_json,
    }, env: {"PATH" => "#{scratch}:#{ENV["PATH"]?}"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"]?.must_be_nil

    calls = File.read(log)
    calls.must_include("--list-icmp-blocks")
    calls.wont_include("--query-icmp-block")
    calls.wont_include("--add-icmp-block")
  end

  it "fails an undefined icmp_block with Ansible's exception text and context msg" do
    scratch = PluginSpecHelper.tmp_path("firewalld-icmp-block-real")
    log, _script, _python = firewalld_cli_stub(scratch)

    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "enabled", "icmp_block" => "ffttre",
      "timeout" => "39",
      "_environment" => {"PATH" => "#{scratch}:/usr/bin:/bin"}.to_json,
    }, env: {"PATH" => "#{scratch}:#{ENV["PATH"]?}"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "ERROR: Exception caught: org.fedoraproject.FirewallD1.Exception: INVALID_ICMPTYPE: ffttre Non-permanent operation"
    )

    calls = File.read(log)
    calls.wont_include("--query-icmp-block")
    calls.must_include("--add-icmp-block=ffttre")
  end
end

require "../minitest_helper"

private MODPROBE_BUILTIN = "/lib/modules/#{File.read("/proc/sys/kernel/osrelease").chomp}/modules.builtin"

describe "modprobe plugin" do
  # AnsibleModule validates the argument spec before anything else
  # (before get_bin_path, before any state check) - verified live against
  # ansible-playbook with the modprobe binary hidden: the state
  # choice error still wins. podman-diff modprobe_edge_cases M2/M3/M9.
  it "fails with Ansible's missing-name arg-spec message" do
    result = PluginSpecHelper.run("modprobe", {"state" => "absent"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails with Ansible's state choice message for an invalid state" do
    result = PluginSpecHelper.run("modprobe", {"name" => "krikri-notamodule", "state" => "loaded"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, got: loaded")
  end

  it "finds an already-loaded module via /proc/modules, dash-normalized (check-mode would-unload)" do
    loaded = File.read("/proc/modules").each_line.map { |line| line.split.first? }.to_a.compact.first?
    skip "no loaded modules visible in /proc/modules" unless loaded

    result = PluginSpecHelper.run("modprobe", {"name" => loaded, "state" => "absent", "_ansible_check_mode" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)

    dashed = loaded.gsub('_', '-')
    result2 = PluginSpecHelper.run("modprobe", {"name" => dashed, "state" => "absent", "_ansible_check_mode" => "true"})
    falsey?(result2["failed"]?.try(&.as_bool)).must_equal(true)
    result2["changed"].as_bool.must_equal(true)
  end

  # Real modprobe.py's module_loaded also scans
  # /lib/modules/$(uname -r)/modules.builtin (builtin modules count as
  # loaded); on a host without that file - typical container -
  # Ansible fails with the raw Python OSError text instead, which the
  # plugin reproduces but only on such a host (verified live via
  # podman-diff modprobe_edge_cases M1/M10).
  it "reports a never-loaded module as an absent no-op when modules.builtin exists" do
    skip "no #{MODPROBE_BUILTIN} on this host" unless File.exists?(MODPROBE_BUILTIN)

    result = PluginSpecHelper.run("modprobe", {"name" => "krikri-notamodule", "state" => "absent"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
  end

  # That OSError is raised inside module_loaded(), which real modprobe.py
  # exits through fail_json(msg=f"{e}", exception=traceback.format_exc(),
  # **self.result) - so the failure still carries the result property's
  # name/params/state (live-verified vs ansible-core 2.21.6 in a
  # container without modules.builtin: registered shape is changed,
  # failed, exception, msg, name, params, state). kpg's
  # multi-modprobe-chaos playbooks caught krikri dropping those three
  # keys (issue #1370). The probe-path override reproduces a container
  # without modules.builtin on a host that ships one.
  it "carries name/params/state on the missing modules.builtin OSError failure" do
    modprobe_present = !Process.find_executable("modprobe").nil? ||
                       %w[/sbin /usr/sbin /bin /usr/bin].any? { |dir| File::Info.executable?(File.join(dir, "modprobe")) }
    skip "no modprobe binary on this host" unless modprobe_present

    missing = PluginSpecHelper.tmp_path("modprobe-no-builtin", File.read("/proc/sys/kernel/osrelease").chomp, "modules.builtin")

    result = PluginSpecHelper.run(
      "modprobe",
      {"name" => "krikri-notamodule", "state" => "absent", "params" => "numdummies=2"},
      env: {"KRIKRI_MODPROBE_MODULES_BUILTIN" => missing}
    )

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("[Errno 2] No such file or directory: '#{missing}'")
    result["name"].as_s.must_equal("krikri-notamodule")
    result["params"].as_s.must_equal("numdummies=2")
    result["state"].as_s.must_equal("absent")
  end
end

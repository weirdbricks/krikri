require "../spec_helper"

private MODPROBE_BUILTIN = "/lib/modules/#{File.read("/proc/sys/kernel/osrelease").chomp}/modules.builtin"

describe "modprobe plugin" do
  # Real AnsibleModule validates the argument spec before anything else
  # (before get_bin_path, before any state check) - verified live against
  # real ansible-playbook with the modprobe binary hidden: the state
  # choice error still wins. podman-diff modprobe_edge_cases M2/M3/M9.
  it "fails with real Ansible's missing-name arg-spec message" do
    result = PluginSpecHelper.run("modprobe", {"state" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails with real Ansible's state choice message for an invalid state" do
    result = PluginSpecHelper.run("modprobe", {"name" => "krikri-notamodule", "state" => "loaded"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, present, got: loaded")
  end

  it "finds an already-loaded module via /proc/modules, dash-normalized (check-mode would-unload)" do
    loaded = File.read("/proc/modules").each_line.map { |line| line.split.first? }.to_a.compact.first?
    pending!("no loaded modules visible in /proc/modules") unless loaded

    result = PluginSpecHelper.run("modprobe", {"name" => loaded, "state" => "absent", "check_mode" => "true"})
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true

    dashed = loaded.gsub('_', '-')
    result2 = PluginSpecHelper.run("modprobe", {"name" => dashed, "state" => "absent", "check_mode" => "true"})
    result2["failed"]?.try(&.as_bool).should be_falsey
    result2["changed"].as_bool.should be_true
  end

  # Real modprobe.py's module_loaded also scans
  # /lib/modules/$(uname -r)/modules.builtin (builtin modules count as
  # loaded); on a host without that file - typical container - real
  # Ansible fails with the raw Python OSError text instead, which the
  # plugin reproduces but only on such a host (verified live via
  # podman-diff modprobe_edge_cases M1/M10).
  it "reports a never-loaded module as an absent no-op when modules.builtin exists" do
    pending!("no #{MODPROBE_BUILTIN} on this host") unless File.exists?(MODPROBE_BUILTIN)

    result = PluginSpecHelper.run("modprobe", {"name" => "krikri-notamodule", "state" => "absent"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
  end
end

require "../spec_helper"
require "../../src/krikri/plugin_helpers/service_mgr_fact"

# Regression anchor for the 2026-09-13 ad-hoc CLI comparison sweep:
# `service: name=cron state=started` in a container with no running
# init returned changed: true "Service started" (the SysV path drove
# the init script directly) where real Ansible failed with "Service is
# in unknown state" - because real Ansible's service ACTION plugin
# dispatches on the ansible_service_mgr fact, whose collector reports
# "systemd" for a container with the systemd package installed but not
# running (offline check), and the systemd module then fails honestly
# when systemctl can't operate.
#
# The two pure decision points of that chain are pinned here; the
# filesystem-dependent fallbacks run live in FactsGatherer and in
# ServicePlugin's probe, and were validated end-to-end against real
# ansible in containers (bash PID 1 + /sbin/init -> systemd: both
# engines report fact "systemd" and fail with "Service is in unknown
# state"; `sleep infinity` PID 1: both engines report fact "sleep" and
# fall back to the generic service module's SysV path).
describe Krikri::PluginHelpers::ServiceMgrFact do
  describe ".from_proc1" do
    it "takes an identifiable PID 1 at face value, like real Ansible" do
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("systemd").should eq("systemd")
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("sleep").should eq("sleep")
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("supervisord").should eq("supervisord")
    end

    it "maps real Ansible's custom-init proc_1_map entries" do
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("procd").should eq("openwrt_init")
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("runit-init").should eq("runit")
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("svscan").should eq("svc")
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("openrc-init").should eq("openrc")
    end

    it "discards 'init' - real Ansible's own comment: too many systems name it" do
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("init").should be_nil
    end

    it "discards anything ending in 'sh' - a container's PID 1 shell" do
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("bash").should be_nil
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("sh").should be_nil
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("zsh").should be_nil
    end

    it "discards an unreadable or empty comm" do
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1(nil).should be_nil
      Krikri::PluginHelpers::ServiceMgrFact.from_proc1("").should be_nil
    end
  end

  describe ".runs_systemd_module?" do
    it "dispatches fact 'systemd' to the systemd module (auto/use unset)" do
      Krikri::PluginHelpers::ServiceMgrFact.runs_systemd_module?(nil, "systemd").should be_true
      Krikri::PluginHelpers::ServiceMgrFact.runs_systemd_module?("auto", "systemd").should be_true
    end

    it "runs the generic service module for every other fact value" do
      # Including values that name no module at all ("sleep") and the
      # generic "service" fact real Ansible falls back to.
      ["sleep", "sysvinit", "service", "upstart", ""].each do |fact|
        Krikri::PluginHelpers::ServiceMgrFact.runs_systemd_module?(nil, fact).should be_false
      end
    end

    it "an explicit use: overrides the fact, and an unrecognized use: falls back to the generic service module" do
      Krikri::PluginHelpers::ServiceMgrFact.runs_systemd_module?("sysvinit", "systemd").should be_false
      Krikri::PluginHelpers::ServiceMgrFact.runs_systemd_module?("openrc", "systemd").should be_false
      Krikri::PluginHelpers::ServiceMgrFact.runs_systemd_module?("bogus", "systemd").should be_false
    end
  end
end

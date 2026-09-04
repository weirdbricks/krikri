require "../spec_helper"
require "../../src/krikri/plugin_helpers/service_facts_parser"

private alias ServiceFactsParser = Krikri::PluginHelpers::ServiceFactsParser

describe ServiceFactsParser do
  describe ".parse_active_states" do
    it "parses a running service correctly despite leading row indentation" do
      # Real bug found benchmarking linux-system-roles.network (round
      # 160): `systemctl list-units --no-legend` still indents every
      # row with leading whitespace. Splitting on /\s+/ without
      # stripping first produces a leading empty-string element,
      # shifting every column one field early - the service name
      # landed under the "" key, and the SUB column check ("running")
      # actually compared against the ACTIVE column instead, so
      # `state` came back "stopped" for every service regardless of
      # its real state.
      output = "  NetworkManager.service                    loaded    active   running Network Manager\n"
      result = ServiceFactsParser.parse_active_states(output)
      result["NetworkManager.service"]?.should eq("running")
      result[""]?.should be_nil
    end

    it "reports a loaded-but-inactive service as stopped" do
      output = "  sshd.service                                loaded    inactive dead    OpenSSH server\n"
      result = ServiceFactsParser.parse_active_states(output)
      result["sshd.service"]?.should eq("stopped")
    end
  end

  describe ".parse_unit_files" do
    it "parses unit file state correctly despite leading row indentation" do
      output = "  sshd.service                               enabled         enabled\n"
      result = ServiceFactsParser.parse_unit_files(output)
      result["sshd.service"]?.should eq("enabled")
    end
  end
end

describe Krikri::PluginHelpers::ServiceFactsParser do
  describe ".parse_sysv_status_all" do
    it "reads running/stopped from `service --status-all`'s +/- markers" do
      output = <<-OUT
       [ - ] apparmor
       [ + ] cron
       [ ? ] hwclock.sh
       [ + ] nginx
      OUT

      result = Krikri::PluginHelpers::ServiceFactsParser.parse_sysv_status_all(output)
      result["cron"].should eq("running")
      result["nginx"].should eq("running")
      result["apparmor"].should eq("stopped")
      # "?" means the init script has no status action at all - real
      # Ansible's regex matches only + and -, so it reports nothing
      # rather than guessing.
      result.has_key?("hwclock.sh").should be_false
    end

    it "ignores blank lines and warning text" do
      output = "\nWarning: something\n [ + ] ssh\n"
      result = Krikri::PluginHelpers::ServiceFactsParser.parse_sysv_status_all(output)
      result.should eq({"ssh" => "running"})
    end

    it "returns an empty hash for empty output" do
      Krikri::PluginHelpers::ServiceFactsParser.parse_sysv_status_all("").should be_empty
    end
  end
end

describe Krikri::PluginHelpers::ServiceFactsParser do
  describe ".parse_units" do
    it "reads state from the SUB column and status from ACTIVE" do
      output = <<-OUT
      ssh.service         loaded active   running OpenSSH server
      cron.service        loaded inactive dead    Regular background jobs
      OUT

      result = Krikri::PluginHelpers::ServiceFactsParser.parse_units(output)
      result["ssh.service"].should eq({state: "running", status: "active"})
      result["cron.service"].should eq({state: "stopped", status: "inactive"})
    end

    it "prefers a bad state over the ACTIVE column" do
      output = "nope.service not-found inactive dead not-found\n"
      Krikri::PluginHelpers::ServiceFactsParser.parse_units(output)["nope.service"]
        .should eq({state: "stopped", status: "not-found"})
    end

    it "scans every field but the last, matching real Ansible's own `fields[:-1]`" do
      # Deliberately NOT "ignores the description": real Ansible excludes
      # only the FINAL field, so a bad-state word earlier in a
      # multi-word description does get picked up as a status. Verified
      # against ansible-core 2.19's own SystemctlScanService. Asserting
      # the idealized behaviour instead would make this engine diverge.
      mid = "ok.service loaded active running Restart failed jobs\n"
      Krikri::PluginHelpers::ServiceFactsParser.parse_units(mid)["ok.service"]
        .should eq({state: "running", status: "failed"})

      last = "ok.service loaded active running failed\n"
      Krikri::PluginHelpers::ServiceFactsParser.parse_units(last)["ok.service"]
        .should eq({state: "running", status: "active"})
    end
  end

  describe ".parse_show_active_states" do
    it "keys by request position, not by the Id field" do
      # An alias reports its TARGET's Id, so keying on Id loses the
      # alias and reports it "unknown" - the bug this guards.
      output = "Id=cryptdisks.service\nActiveState=inactive\n\nId=systemd-logind.service\nActiveState=active\n"
      requested = ["cryptdisks.service", "dbus-org.freedesktop.login1.service"]
      result = Krikri::PluginHelpers::ServiceFactsParser.parse_show_active_states(output, requested)
      result.should eq({"cryptdisks.service" => "inactive", "dbus-org.freedesktop.login1.service" => "active"})
    end

    it "returns nil when the block count does not match the request" do
      # systemctl fails the WHOLE batch on one un-showable unit, so a
      # short result must trigger the caller's per-unit fallback rather
      # than silently mis-pairing names with states.
      output = "ActiveState=inactive\n"
      Krikri::PluginHelpers::ServiceFactsParser
        .parse_show_active_states(output, ["a.service", "b.service"]).should be_nil
    end
  end

  describe ".showable_unit?" do
    it "rejects a template unit with an empty instance" do
      Krikri::PluginHelpers::ServiceFactsParser.showable_unit?("autovt@.service").should be_false
      Krikri::PluginHelpers::ServiceFactsParser.showable_unit?("getty@.service").should be_false
    end

    it "accepts a real instance and an ordinary unit" do
      Krikri::PluginHelpers::ServiceFactsParser.showable_unit?("getty@tty1.service").should be_true
      Krikri::PluginHelpers::ServiceFactsParser.showable_unit?("ssh.service").should be_true
    end
  end
end

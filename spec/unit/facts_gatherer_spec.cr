require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Perf item 2 - `facts` under the daemon.
#
# The item itself is one line (drop "facts" from
# DAEMON_INELIGIBLE_PLUGINS); the actual work, and the actual risk, was
# getting `facts` INTO the fat plugin binary so a daemon request for it
# does not hit the generated dispatcher's "unknown plugin" fallback.
# That meant lifting the whole gathering body out of the top level of
# `plugins/facts.cr` into `Krikri::FactsGatherer`, which is exactly
# the kind of move that quietly changes a payload.
#
# So what is pinned here is the CONTRACT the extraction had to preserve:
# the same three top-level keys, no others (notably no `msg` on the
# success path - the reason this was not reshaped into a BasePlugin
# subclass, whose PluginResult always emits one), and gather_subset
# still honoured. The live daemon round trip is verified separately in
# plugin_daemon_spec.cr.
describe Krikri::FactsGatherer do
  it "returns the same three top-level keys the standalone driver always emitted" do
    result = JSON.parse(Krikri::FactsGatherer.run(nil))

    result.as_h.keys.sort!.should eq(["ansible_facts", "changed", "failed"])
    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    # An always-empty "msg" would be the tell-tale of a BasePlugin
    # reshape; there has never been one on the success payload.
    result["msg"]?.should be_nil
  end

  it "gathers a full fact set with no config at all" do
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

    # Spot-check the families every real role reads first.
    facts["ansible_system"]?.should_not be_nil
    facts["ansible_os_family"]?.should_not be_nil
    facts["ansible_distribution"]?.should_not be_nil
    facts["ansible_hostname"]?.should_not be_nil
  end

  it "always sets ansible_system_vendor, even when DMI info isn't readable" do
    # Real Ansible's DMI collector falls back to "NA" rather than leaving
    # the fact undefined - a `when: ansible_system_vendor == 'QEMU'` guard
    # (sbaerlocher.qemu-guest-agent/.ovirt-guest-agent's own idiom) must
    # always have something to compare against, never raise "undefined".
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
    facts["ansible_system_vendor"]?.should_not be_nil
    facts["ansible_system_vendor"].as_s.should_not be_empty
  end

  it "always sets ansible_product_version, even when DMI info isn't readable" do
    # Same class as ansible_system_vendor above - robertdebock.bios_update's
    # own rescue: block references ansible_product_version in a debug: msg,
    # which must always resolve to something rather than raise "undefined".
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
    facts["ansible_product_version"]?.should_not be_nil
    facts["ansible_product_version"].as_s.should_not be_empty
  end

  it "always sets ansible_fips as a real boolean" do
    # Real Ansible's FipsFactCollector always populates this (true only
    # when /proc/sys/crypto/fips_enabled reads exactly "1") - and as a
    # genuine JSON bool, NOT a "False" string: a string "False" is
    # truthy under Jinja2 semantics, so geerlingguy.postgresql's own
    # `{{ ansible_fips | ternary('scram-sha-256', 'md5') }}` (flowing
    # into pg_hba.conf) would pick the FIPS branch on every host. With
    # the fact missing entirely, the ternary rendered the literal text
    # "undefined" into pg_hba.conf and postgresql.service refused to
    # start after a successful initdb (round 65000+).
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
    facts["ansible_fips"]?.should_not be_nil
    facts["ansible_fips"].as_bool.should be_a(Bool)
  end

  it "honours gather_subset from the config it is handed" do
    # The daemon hands over an already-parsed JSON::Any rather than a
    # STDIN string, so this is the shape that matters now.
    config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":{"gather_subset":"min"},"vars":{}}))

    full = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
    minimal = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h

    minimal.size.should be < full.size
    # min still carries the identity facts - it drops families, not
    # the basics every play needs.
    minimal["ansible_system"]?.should_not be_nil
    minimal["ansible_distribution"]?.should_not be_nil
  end

  it "tolerates a config carrying no params at all" do
    config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"vars":{}}))
    result = JSON.parse(Krikri::FactsGatherer.run(config))

    result["failed"].as_bool.should be_false
    result["ansible_facts"].as_h.should_not be_empty
  end

  describe "#parse_container_env" do
    # Found live confirming the round-303 dict-iteration fix via
    # `jtyr.motd`: a minimal podman container with no systemd package
    # installed has neither `systemd-detect-virt` nor
    # `/run/systemd/container`, so #detect_virtualization's only other
    # checks (dockerenv/cgroup substring/systemd-detect-virt/DMI) all
    # fell through to "None" while real ansible-playbook (whose primary
    # signal is PID 1's own `container=` environment variable, per
    # module_utils/facts/virtual/linux.py) correctly reported "podman".
    # `/proc/1/environ` is NUL-separated, not newline-separated.
    it "detects podman from a NUL-separated container=podman entry" do
      environ = "PATH=/usr/bin\x00container=podman\x00HOME=/root\x00"
      Krikri::FactsGatherer.parse_container_env(environ).should eq("podman")
    end

    it "detects lxc from container=lxc, taking priority over a later generic entry" do
      environ = "container=lxc\x00SOME_VAR=1\x00"
      Krikri::FactsGatherer.parse_container_env(environ).should eq("lxc")
    end

    it "normalizes any other non-empty container= marker to the generic literal 'container', not the raw value" do
      # Real Ansible's `^container=.` branch (linux.py) only special-
      # cases lxc/podman above; every other value - docker, systemd-
      # nspawn, oci, ... - sets virtualization_type to the literal
      # string "container", never the matched value itself. Previously
      # this returned the raw value verbatim, so a Kata VM whose guest
      # environ happened to carry `container=docker` (a leftover from
      # the base rootfs having been built via `podman build`/
      # Containerfile, even though Kata boots a real, non-containerized
      # guest kernel) reported "docker" - matching a role's `== "docker"`
      # when: check that real Ansible correctly left false. Found
      # benchmarking juju4.auditd's "Not in container" block guard.
      environ = "container=systemd-nspawn\x00PATH=/usr/bin\x00"
      Krikri::FactsGatherer.parse_container_env(environ).should eq("container")

      environ2 = "container=docker\x00PATH=/usr/bin\x00"
      Krikri::FactsGatherer.parse_container_env(environ2).should eq("container")
    end

    it "returns nil on a plain host with no container= entry at all" do
      environ = "PATH=/usr/bin\x00HOME=/root\x00TERM=xterm\x00"
      Krikri::FactsGatherer.parse_container_env(environ).should be_nil
    end

    it "returns nil rather than an empty string for a bare 'container=' with no value" do
      environ = "container=\x00PATH=/usr/bin\x00"
      Krikri::FactsGatherer.parse_container_env(environ).should be_nil
    end
  end

  describe "#detect_virtualization" do
    it "returns a non-empty string on this real host, matching real Ansible's always-populated virtualization_type" do
      # Live-environment smoke test, not a controlled-input unit test -
      # this repo's own convention for facts that read real /proc/DMI
      # state (see #parse_container_env above for the actual regression
      # coverage of the new logic).
      Krikri::FactsGatherer.detect_virtualization.should_not be_empty
    end
  end

  describe "ansible_memory_mb (ansible_facts.memory_mb)" do
    it "gathers the namespaced memory dict, not just the legacy flat facts" do
      # Found via geerlingguy.swap's "Disable swap (if configured).":
      # `when: ansible_facts.memory_mb['swap']['total'] > 0` died with
      # "object of type 'dict' has no attribute 'memory_mb'" - only the
      # legacy ansible_memtotal_mb/ansible_swaptotal_mb/... flat facts
      # existed, the namespaced dict real ansible-core's Linux hardware
      # collector produces (real/nocache/swap) was never gathered.
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

      mem_mb = facts["ansible_memory_mb"]?.should_not be_nil
      mem_mb = mem_mb.as_h
      mem_mb["swap"]?.should_not be_nil
      mem_mb["real"]?.should_not be_nil
      mem_mb["nocache"]?.should_not be_nil

      swap = mem_mb["swap"].as_h
      swap["total"]?.should_not be_nil
      swap["free"]?.should_not be_nil
      swap["used"]?.should_not be_nil

      # Consistency with the legacy flat facts (real Ansible derives
      # both from the same /proc/meminfo line).
      if (legacy_total = facts["ansible_swaptotal_mb"]?.try(&.as_i64?)) && (ns_total = swap["total"].as_i64?)
        ns_total.should eq(legacy_total)
      end
      if (legacy_memtotal = facts["ansible_memtotal_mb"]?.try(&.as_i64?)) && (real_total = mem_mb["real"].as_h["total"].as_i64?)
        real_total.should eq(legacy_memtotal)
      end
    end
  end
end

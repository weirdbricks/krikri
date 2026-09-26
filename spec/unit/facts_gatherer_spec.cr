require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"
require "../../src/krikri/variable_substitutor/jinja_renderer"
require "../../src/krikri/krikri_jinja_filters"

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
    result["failed"]?.try(&.as_bool).should be_falsey
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

  it "always sets ansible_processor_threads_per_core on hosts whose cpuinfo has siblings and cpu cores" do
    # Real Ansible's Linux hardware collector always derives this fact
    # (siblings / cpu cores from /proc/cpuinfo) - marvel-nccr.slurm's
    # templates/slurm.conf references it directly, and with the fact
    # never set the template died with "is undefined" while real
    # ansible-playbook completes. Value varies by host, so only pin
    # presence and positivity.
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
    facts["ansible_processor_threads_per_core"]?.should_not be_nil
    facts["ansible_processor_threads_per_core"].as_i64.should be > 0
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

    result["failed"]?.try(&.as_bool).should be_falsey
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

  describe "#parse_lsb_release" do
    # Real Ansible's LSBFactCollector always derives major_release from
    # release whenever the lsb dict has a release at all (lsb.py:
    # `lsb_facts['major_release'] = lsb_facts['release'].split('.')[0]`),
    # confirmed live: `ansible localhost -m setup -a filter=ansible_lsb`
    # on LMDE 7 (release "7", no dot) reports major_release "7" verbatim.
    # This engine only set id/description/release/codename, so avnes.plank's
    # own `when: ansible_lsb.major_release|int >= 16` raised
    # "'ansible_lsb.major_release' is undefined" where real Ansible's
    # when: passed cleanly (round900297).
    it "derives major_release as the portion of release before the first dot" do
      lsb = Krikri::FactsGatherer.parse_lsb_release(
        %(DISTRIB_ID=Ubuntu\nDISTRIB_RELEASE="22.04"\nDISTRIB_CODENAME="jammy"\nDISTRIB_DESCRIPTION="Ubuntu 22.04.5 LTS"\n)
      )
      lsb["major_release"].should eq("22")
      lsb["release"].should eq("22.04")
    end

    it "passes a dotless release through verbatim as major_release" do
      # Python's str.split('.')[0] is the whole string when there is no
      # dot - LMDE 7's release is just "7" and real Ansible reports
      # major_release "7" (verified live on this machine).
      lsb = Krikri::FactsGatherer.parse_lsb_release(
        %(DISTRIB_ID=Linuxmint\nDISTRIB_RELEASE=7\nDISTRIB_CODENAME=gigi\nDISTRIB_DESCRIPTION="LMDE 7 (gigi)"\n)
      )
      lsb["major_release"].should eq("7")
    end

    it "omits major_release (like the other keys) when release is absent" do
      # Real Ansible gates the derivation on `'release' in lsb_facts` - a
      # dict without release stays without major_release.
      lsb = Krikri::FactsGatherer.parse_lsb_release(%(DISTRIB_ID=Debian\nDISTRIB_CODENAME=bookworm\n))
      lsb.has_key?("major_release").should be_false
      lsb.has_key?("release").should be_false
      lsb["id"].should eq("Debian")
    end

    it "returns an empty dict for empty content, matching the always-defined-but-possibly-empty ansible_lsb" do
      Krikri::FactsGatherer.parse_lsb_release("").should be_empty
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

  describe "#fqdn_from_getent_hosts" do
    # ansible_fqdn must come from socket.getfqdn()'s REVERSE-lookup
    # algorithm, not `hostname -f`'s forward lookup of the name itself.
    # oasis_roles.hostname sets a short hostname and colocates it on the
    # 127.0.0.1 line of /etc/hosts; reverse-resolving 127.0.0.1 there
    # yields "localhost localhost.localdomain", and Python skips the
    # dotless "localhost" in favor of "localhost.localdomain" - so real
    # ansible-playbook reports ansible_fqdn as "localhost.localdomain"
    # (and keeps re-reporting changed on the role's hostname:/blockinfile:
    # tasks every run) while a `hostname -f`-based value stays at the
    # short name, making this engine falsely idempotent. These pin the
    # parse of that reverse-lookup output; the shelling-out half of the
    # algorithm stays a live-host concern, same convention as
    # #detect_virtualization above.
    it "prefers the first dot-qualified name over the dotless canonical one" do
      Krikri::FactsGatherer.fqdn_from_getent_hosts("127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4").should eq("localhost.localdomain")
    end

    it "returns the canonical name when it already carries a dot" do
      Krikri::FactsGatherer.fqdn_from_getent_hosts("10.0.0.5 myhost.example.com").should eq("myhost.example.com")
    end

    it "scans aliases in order after the canonical name" do
      Krikri::FactsGatherer.fqdn_from_getent_hosts("10.0.0.5 short alias.example.com other").should eq("alias.example.com")
    end

    it "returns empty when every name is dotless, triggering the plain-hostname fallback" do
      Krikri::FactsGatherer.fqdn_from_getent_hosts("127.0.0.1 myhost").should eq("")
    end

    it "returns empty for a bare address with no names at all" do
      Krikri::FactsGatherer.fqdn_from_getent_hosts("127.0.0.1").should eq("")
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

  describe "ansible_devices" do
    # Found via Tecnativa.hetzner_rescue_installimage's templates/autosetup.j2:
    # `{% for device in ansible_devices if device.startswith("sd") ... %}` died
    # with "can't iterate over undefined" because the fact was never gathered
    # at all - real Ansible's setup module always defines the key (even as an
    # empty dict), so the role's "configure installation" task succeeds there.
    it "is always present, never omitted - even when the /sys/block scan finds nothing" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

      devices = facts["ansible_devices"]?.should_not be_nil
      # A dict, so `{% for device in ansible_devices %}` iterates (possibly
      # zero times) instead of erroring.
      devices.as_h?.should_not be_nil
    end

    it "contains real block-device names as keys on this host" do
      # Live-environment smoke test, same convention as the virtualization
      # facts above: the controlled-input regression is the always-set
      # contract plus the template rendering spec below.
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      devices = facts["ansible_devices"].as_h

      pending! "no block devices on this host" if devices.empty?

      devices.keys.each do |name|
        # Real Ansible's DEVICE_EXCLUDE_PATTERNS drops loopback and ram.
        name.should_not match(/^(loop|ram)/)
      end
      dev = devices.each_value.first.as_h
      dev["partitions"]?.should_not be_nil
      dev["virtual"]?.should_not be_nil
    end

    it "renders Tecnativa.hetzner_rescue_installimage's autosetup.j2 loop shape" do
      # The empty-dict case is the shape a minimal container presents; the
      # loop must be a zero-iteration no-op, not "can't iterate over
      # undefined". Rendered through the real JinjaRenderer wrapper, same
      # pattern as ansible_mounts_numeric_stats_spec.cr.
      vars = {"ansible_devices" => JSON.parse(%({}))}
      renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(vars)

      template = <<-TPL
        {% for device in ansible_devices if device.startswith("sd") or device.startswith("nvme") -%}
        DRIVE{{ loop.index }} /dev/{{ device }}
        {% endfor %}
        TPL

      renderer.render(template).strip.should eq("")
    end

    it "renders the autosetup.j2 loop shape over a populated device dict" do
      vars = {"ansible_devices" => JSON.parse(%({"sda": {"partitions": {}, "virtual": "0", "size": "111.79 GB", "sectors": 234441648}, "vdb": {"partitions": {}, "virtual": "0", "size": "10.00 GB", "sectors": 20971520}}))} of String => JSON::Any
      renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(vars)

      template = <<-TPL
        {% for device in ansible_devices if device.startswith("sd") or device.startswith("nvme") -%}
        DRIVE{{ loop.index }} /dev/{{ device }}
        {% endfor %}
        TPL

      renderer.render(template).strip.should eq("DRIVE1 /dev/sda")
    end
  end

  describe "min-bundle parity with real Ansible (podman-diff setup case)" do
    # Found adding the setup edge cases to the podman-diff harness: real
    # ansible-core's min bundle (`gather_subset: "!all"`) reports several
    # facts this engine never gathered at all, and two families
    # (virtualization, DMI) this engine reported UNDER MIN that real
    # Ansible only reports under the virtual/hardware subsets.
    config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":{"gather_subset":"!all"},"vars":{}}))

    it "always sets ansible_dns (empty dict when resolv.conf has nothing usable)" do
      facts = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h
      facts["ansible_dns"]?.should_not be_nil
      facts["ansible_dns"].as_h?.should_not be_nil
    end

    it "sets ansible_cmdline/ansible_proc_cmdline with flag=True and k=v semantics" do
      parsed = Krikri::FactsGatherer.parse_cmdline("quiet splash root=UUID=abc-1 console=tty0 console=ttyS0", false)
      parsed["quiet"].as_bool.should be_true
      parsed["root"].as_s.should eq("UUID=abc-1")
      parsed["console"].as_s.should eq("ttyS0")

      multi = Krikri::FactsGatherer.parse_cmdline("console=tty0 console=ttyS0", true)
      multi["console"].as_a.map(&.as_s).should eq(["tty0", "ttyS0"])

      empty_value = Krikri::FactsGatherer.parse_cmdline("opt=", false)
      empty_value["opt"].as_s.should eq("")
    end

    it "sets the real/effective user and group id facts" do
      facts = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h
      facts["ansible_real_user_id"]?.should_not be_nil
      facts["ansible_real_group_id"]?.should_not be_nil
      facts["ansible_effective_user_id"]?.should_not be_nil
      facts["ansible_effective_group_id"]?.should_not be_nil
      facts["ansible_effective_user_id"].as_i64.should eq(facts["ansible_user_uid"].as_i64)
    end

    it "sets ansible_system_capabilities/_enforced (real N/A defaults without capsh)" do
      facts = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h
      facts["ansible_system_capabilities_enforced"]?.should_not be_nil
      facts["ansible_system_capabilities"]?.should_not be_nil
    end

    it "reports ansible_distribution_minor_version even for dotless VERSION_ID" do
      facts = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h
      facts["ansible_distribution_minor_version"]?.should_not be_nil
    end

    it "does NOT report virtualization facts under min" do
      facts = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h
      facts["ansible_virtualization_type"]?.should be_nil
      facts["ansible_virtualization_role"]?.should be_nil
    end

    it "reports virtualization facts (incl. the tech lists) under the default all gather" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      facts["ansible_virtualization_type"]?.should_not be_nil
      facts["ansible_virtualization_role"]?.should_not be_nil
      facts["ansible_virtualization_tech_guest"]?.should_not be_nil
      facts["ansible_virtualization_tech_host"]?.should_not be_nil
      facts["ansible_virtualization_tech_host"].as_a.should be_empty
    end

    it "reports processor_nproc and uptime under the default gather" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      facts["ansible_processor_nproc"]?.should_not be_nil
      facts["ansible_processor_nproc"].as_i64.should be > 0
      facts["ansible_uptime_seconds"]?.should_not be_nil
      facts["ansible_uptime_seconds"].as_i64.should be > 0
    end

    it "reports the DMI set under the default gather" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      %w[ansible_system_vendor ansible_product_version ansible_product_name
        ansible_product_serial ansible_product_uuid ansible_bios_vendor
        ansible_bios_version ansible_bios_date ansible_board_vendor
        ansible_board_name ansible_chassis_vendor ansible_form_factor
        ansible_lvm ansible_device_links].each do |key|
        facts[key]?.should_not be_nil
      end
      # The lvs/vgs dicts are always present (empty on hosts without LVM).
      facts["ansible_lvm"].as_h["lvs"].as_h?.should_not be_nil
      facts["ansible_lvm"].as_h["vgs"].as_h?.should_not be_nil
    end

    it "resolves the new family subsets like real Ansible's alias map" do
      Krikri::FactsGatherer.resolve_enabled_families(["virtualization_type"]).should contain("virtual")
      Krikri::FactsGatherer.resolve_enabled_families(["is_chroot"]).should contain("is_chroot")
      Krikri::FactsGatherer.resolve_enabled_families(["all"]).should contain("virtual")
      Krikri::FactsGatherer.resolve_enabled_families(["!all"]).should_not contain("virtual")
      # !virtualization_type excludes the whole alias family, not just one fact.
      Krikri::FactsGatherer.resolve_enabled_families(["!virtualization_type"]).should_not contain("virtual")
    end
  end
end

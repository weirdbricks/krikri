require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Pins the two real-Ansible scoping rules krikri's setup facts were
# missing, both found and live-verified via the podman-diff
# setup_edge_cases_v2 harness (FS3/FS5 divergence) against real
# ansible-core 2.14 inside a debian:bookworm-slim podman container:
#
# - FS3 mounts: real's hardware/linux.py get_mount_facts skips any
#   mount whose device is not a local device path (no "/" prefix, no
#   ":/" NFS export) and any fstype of "none". In a container every
#   mount device is overlay/proc/tmpfs/udev/etc, so real reports an
#   EMPTY ansible_mounts despite /proc/mounts listing 150+ entries -
#   krikri used to report all of them.
# - FS5 network: real's network/linux.py LinuxNetwork.populate returns
#   an empty dict BEFORE any gathering when get_bin_path('ip') is None.
#   bookworm-slim ships no iproute2, so real reports NO network facts
#   (no ansible_interfaces, no 'lo', no default_ipv4, no
#   all_ipv4_addresses) even though /sys/class/net still lists lo -
#   krikri used to populate ansible_interfaces from /sys/class/net
#   unconditionally, so `when: 'lo' in ansible_interfaces` diverged.
describe Krikri::FactsGatherer do
  describe "real Ansible's mount device-path filter" do
    it "keeps local device paths" do
      Krikri::FactsGatherer.real_mount_device_kept?("/dev/vg0/lv0", "ext4").should be_true
      Krikri::FactsGatherer.real_mount_device_kept?("/dev/mapper/vg0-lv0", "xfs").should be_true
      Krikri::FactsGatherer.real_mount_device_kept?("/loop0", "squashfs").should be_true
    end

    it "keeps NFS-style exports (host:/path)" do
      Krikri::FactsGatherer.real_mount_device_kept?("192.168.1.10:/export", "nfs4").should be_true
    end

    it "drops pseudo-filesystem devices and fstype=none (FS3: real reports empty mounts in a container)" do
      Krikri::FactsGatherer.real_mount_device_kept?("overlay", "overlay").should be_false
      Krikri::FactsGatherer.real_mount_device_kept?("proc", "proc").should be_false
      Krikri::FactsGatherer.real_mount_device_kept?("tmpfs[/containers/overlay-containers/x/userdata]", "tmpfs").should be_false
      Krikri::FactsGatherer.real_mount_device_kept?("udev[/random]", "devtmpfs").should be_false
      Krikri::FactsGatherer.real_mount_device_kept?("cgroup2", "cgroup2").should be_false
      Krikri::FactsGatherer.real_mount_device_kept?("/dev/sda1", "none").should be_false
    end

    it "only ever reports mounts that pass the same filter (live-gathered invariant)" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      mounts = facts["ansible_mounts"]?.try(&.as_a?) || [] of JSON::Any
      mounts.each do |mount|
        Krikri::FactsGatherer.real_mount_device_kept?(
          mount["device"].as_s, mount["fstype"].as_s,
        ).should be_true
      end
    end
  end

  describe "the ip-binary gate on network facts" do
    it "reports network facts only when real's get_bin_path('ip') would find one (FS5)" do
      # Same lookup real get_bin_path does over PATH - the harness
      # containers (bookworm-slim, no iproute2) resolve nil and real
      # emits no network facts at all; krikri must match that there.
      ip_present = ((ENV["PATH"]?.try(&.split(':')) || [] of String) +
                    ["/sbin", "/usr/sbin", "/bin", "/usr/bin"]).any? do |dir|
        !dir.empty? && File.executable?(File.join(dir, "ip"))
      end

      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

      if ip_present
        facts["ansible_interfaces"]?.should_not be_nil
      else
        facts["ansible_interfaces"]?.should be_nil
        facts["ansible_default_ipv4"]?.should be_nil
        facts["ansible_all_ipv4_addresses"]?.should be_nil
        facts.keys.any?(&.starts_with?("ansible_lo")).should be_false
      end
    end
  end
end

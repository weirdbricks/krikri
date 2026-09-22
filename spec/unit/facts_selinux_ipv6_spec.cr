require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Pins two fact-presence fixes, both against real Ansible's own
# collector semantics:
#
# - ansible_selinux.status: real's SelinuxFactCollector loads
#   libselinux.so.1 via ctypes (CDLL('libselinux.so.1')) - Ubuntu ships
#   libselinux1 as a base dependency even on hosts that never use
#   SELinux, so real correctly reports "disabled" there. krikri gated on
#   the `getenforce` binary instead (policycoreutils, NOT installed on
#   stock Ubuntu) and reported "Missing selinux Python library", so
#   linux-system-roles.selinux's own
#   `when: ansible_facts['selinux']['status'] == "disabled"` warn task
#   wrongly skipped (round 952352).
# - ansible_all_ipv6_addresses: real's LinuxNetwork collector ALWAYS
#   emits this fact (an empty list when there is no IPv6 beyond ::1),
#   never simply absent. krikri never set it, so
#   linux-system-roles.kdump's set_vars.yml gate
#   `__kdump_required_facts | difference(ansible_facts.keys()|list) |
#   length > 0` never emptied and a redundant setup task re-ran
#   (round 952548).
# Independent re-derivation of the libselinux probe (different code
# path from the engine's own helper, which goes ldconfig-cache first)
# so a broken probe cannot make these specs pass tautologically.
private def libselinux_present_locally? : Bool
  return true if File.exists?("/usr/lib/x86_64-linux-gnu/libselinux.so.1")
  return true if File.exists?("/usr/lib/aarch64-linux-gnu/libselinux.so.1")
  return true if File.exists?("/usr/lib64/libselinux.so.1")
  return true unless Dir.glob("/usr/lib/*/libselinux.so.1").empty?
  return true unless Dir.glob("/lib/*/libselinux.so.1").empty?

  ldconfig = Process.find_executable("ldconfig")
  return false unless ldconfig
  output = IO::Memory.new
  Process.run(ldconfig, ["-p"], output: output, error: Process::Redirect::Close)
  output.to_s.includes?("libselinux.so.1")
end

describe Krikri::FactsGatherer do
  describe "ansible_selinux.status" do
    it "reports 'disabled' when the libselinux library exists but SELinux is not active in the kernel (the stock-Ubuntu shape, round 952352)" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      selinux = facts["ansible_selinux"].as_h

      if libselinux_present_locally?
        if Dir.exists?("/sys/fs/selinux")
          ["enabled"].should contain(selinux["status"].as_s)
        else
          selinux["status"].as_s.should eq("disabled")
          selinux["mode"]?.should be_nil
        end
      else
        selinux["status"].as_s.should eq("Missing selinux Python library")
      end
    end

    it "reports 'Missing selinux Python library' only when the library is genuinely absent, and keeps selinux_python_present consistent with it" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
      status = facts["ansible_selinux"].as_h["status"].as_s
      python_present = facts["ansible_selinux_python_present"].as_s

      if status == "Missing selinux Python library"
        libselinux_present_locally?.should be_false
        python_present.should eq("False")
      else
        libselinux_present_locally?.should be_true
        python_present.should eq("True")
      end
    end
  end

  describe "ansible_all_ipv6_addresses" do
    it "is always set once network facts are gathered, even with no IPv6 beyond ::1 (round 952548)" do
      facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

      # Same ip-binary gate real Ansible's LinuxNetwork.populate applies
      # before gathering anything: without iproute2 there are no network
      # facts at all (see facts_mount_network_scoping_spec.cr for FS5).
      ip_present = ((ENV["PATH"]?.try(&.split(':')) || [] of String) +
                    ["/sbin", "/usr/sbin", "/bin", "/usr/bin"]).any? do |dir|
        !dir.empty? && File.executable?(File.join(dir, "ip"))
      end

      next unless ip_present

      all_ipv6 = facts["ansible_all_ipv6_addresses"]?
      all_ipv6.should_not be_nil
      addresses = all_ipv6.not_nil!.as_a.map(&.as_s)

      # Real Ansible's own exclusion (network/linux.py's
      # `if not address == '::1'`): lo's one address must not make a
      # no-IPv6 host look like it has one.
      addresses.should_not contain("::1")

      listed = `ip -6 addr show 2>/dev/null | grep 'inet6 ' | awk '{print $2}' | cut -d/ -f1`.split
      expect = listed.reject("::1").uniq.sort
      addresses.uniq.sort.should eq(expect)
    end
  end
end

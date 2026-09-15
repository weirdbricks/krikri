require "../spec_helper"

# seport's argument validation must happen BEFORE the SELinux-enabled
# gate, matching real's argument_spec (podman-diff harness R4/R5/R11:
# real reports the proto/state choices failure and the bool-conversion
# failure on a host with no SELinux at all; krikri used to reach the
# "SELinux is disabled" gate first). No SELinux host is needed here:
# the point is precisely that these failures happen without one.
describe "seport argument validation order" do
  it "rejects an invalid proto before the SELinux gate" do
    result = PluginSpecHelper.run("seport", {
      "ports"  => "8080",
      "proto"  => "krikri_proto",
      "setype" => "krikri_port_t",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq(
      "value of proto must be one of: tcp, udp, dccp, sctp, got: krikri_proto")
  end

  it "rejects an invalid state before the SELinux gate" do
    result = PluginSpecHelper.run("seport", {
      "ports"  => "8080",
      "proto"  => "tcp",
      "setype" => "krikri_port_t",
      "state"  => "krikri_state",
    })

    result["msg"].as_s.should eq(
      "value of state must be one of: absent, present, got: krikri_state")
  end

  it "rejects state with wrong case like real's case-sensitive choices check" do
    result = PluginSpecHelper.run("seport", {
      "ports"  => "8080",
      "proto"  => "tcp",
      "setype" => "krikri_port_t",
      "state"  => "PRESENT",
    })

    result["msg"].as_s.should eq(
      "value of state must be one of: absent, present, got: PRESENT")
  end

  it "rejects a non-boolean ignore_selinux_state before the SELinux gate" do
    result = PluginSpecHelper.run("seport", {
      "ports"                => "8080",
      "proto"                => "tcp",
      "setype"               => "krikri_port_t",
      "ignore_selinux_state" => "krikri-not-a-bool",
    })

    result["msg"].as_s.should contain(
      "argument 'ignore_selinux_state' is of type <class 'str'> and we were unable to convert to bool")
    result["msg"].as_s.should contain("not a valid boolean")
  end

  it "still fails valid-args cases on the SELinux gate (not the new validations)" do
    result = PluginSpecHelper.run("seport", {
      "ports"  => "8080",
      "proto"  => "tcp",
      "setype" => "krikri_port_t",
    })

    result["msg"].as_s.should eq("SELinux is disabled on this host.")
  end
end

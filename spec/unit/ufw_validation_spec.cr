require "../spec_helper"

# Pins plugins/ufw.cr's argument-validation surface against real
# community.general.ufw's AnsibleModule setup (live-diffed vs real
# ansible-playbook via the podman-diff ufw_edge_cases harness in a
# ufw-less container - real runs all of this BEFORE its
# get_bin_path(required=True), the only byte-comparable surface without
# a working ufw/netfilter):
#
# - required_one_of (state/default/rule/logging) AFTER the
#   mutually-exclusive tuples, so name+proto alone reports the
#   exclusivity, not the missing action (live-verified ordering)
# - mutually-exclusive tuples list the WHOLE tuple pipe-joined
#   regardless of which members are present, one message per tuple
# - choices in argument_spec declaration order (NOT sorted)
# - delete/route/log type=bool, insert type=int, with parameters.py
#   convert wording
# - required_by: interface needs direction
# - unsupported params: spec keys sorted, then ONE trailing
#   parenthetical holding every alias sorted (live-verified format)
describe "ufw plugin argument validation" do
  it "fails with no action key (required_one_of)" do
    result = PluginSpecHelper.run("ufw", {"comment" => "krikri"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("one of the following is required: state, default, rule, logging")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("ufw", {"state" => "krikri_state"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: enabled, disabled, reloaded, reset, got: krikri_state")
  end

  it "fails an invalid default/policy choice" do
    result = PluginSpecHelper.run("ufw", {"default" => "krikri_policy"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of default must be one of: allow, deny, reject, got: krikri_policy")
  end

  it "fails an invalid logging choice (spec order: full high low medium off on)" do
    result = PluginSpecHelper.run("ufw", {"logging" => "krikri_level"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of logging must be one of: full, high, low, medium, off, on, got: krikri_level")
  end

  it "fails an invalid direction choice before the required action check" do
    result = PluginSpecHelper.run("ufw", {"direction" => "krikri_dir", "logging" => "low"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of direction must be one of: in, incoming, out, outgoing, routed, got: krikri_dir")
  end

  it "fails an invalid rule choice" do
    result = PluginSpecHelper.run("ufw", {"rule" => "krikri_rule"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of rule must be one of: allow, deny, limit, reject, got: krikri_rule")
  end

  it "fails an invalid proto choice" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "proto" => "krikri_proto"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of proto must be one of: ah, any, esp, ipv6, tcp, udp, gre, igmp, vrrp, got: krikri_proto")
  end

  it "fails an invalid insert_relative_to choice" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "insert" => "1", "insert_relative_to" => "krikri_rel"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "value of insert_relative_to must be one of: zero, first-ipv4, last-ipv4, first-ipv6, last-ipv6, got: krikri_rel")
  end

  it "fails the whole mutually-exclusive tuple pipe-joined, regardless of members present" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "name" => "krikri_app", "proto" => "tcp"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: name|proto|logging")
  end

  it "fails direction+interface_in (whole tuple)" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "direction" => "in", "interface_in" => "eth0"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: direction|interface_in")
  end

  it "reports the mutual exclusivity INSTEAD of required_one_of when both would fire" do
    result = PluginSpecHelper.run("ufw", {"name" => "krikri_app", "proto" => "tcp"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: name|proto|logging")
  end

  it "fails interface without direction (required_by)" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "interface" => "eth0"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing parameter(s) required by 'interface': direction")
  end

  it "fails a non-boolean delete with parameters.py wording" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "delete" => "krikri-not-a-bool"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'delete' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'krikri-not-a-bool' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails a non-integer insert with parameters.py wording" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "insert" => "not-an-int"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'insert' is of type <class 'str'> and we were unable to convert to int: " \
                                 "<class 'str'> cannot be converted to an int")
  end

  it "rejects unsupported parameters with the all-aliases parenthetical" do
    result = PluginSpecHelper.run("ufw", {"rule" => "allow", "krikri_param" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.ufw) module: krikri_param. " \
                                 "Supported parameters include: comment, default, delete, direction, from_ip, from_port, " \
                                 "insert, insert_relative_to, interface, interface_in, interface_out, log, logging, name, " \
                                 "proto, route, rule, state, to_ip, to_port " \
                                 "(app, dest, from, if, if_in, if_out, policy, port, protocol, src, to).")
  end

  it "accepts the policy alias for default and valid args, failing only later on the missing ufw binary" do
    result = PluginSpecHelper.run("ufw", {"policy" => "allow", "direction" => "outgoing"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("value of")
  end
end

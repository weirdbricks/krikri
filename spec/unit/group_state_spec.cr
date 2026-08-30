require "../spec_helper"
require "../../src/krikri/plugin_helpers/group_state"

private alias GroupState = Krikri::PluginHelpers::GroupState

describe GroupState do
  describe ".parse" do
    it "parses a getent group line" do
      group = GroupState.parse("developers:x:1001:alice,bob").as(GroupState::Group)
      group.name.should eq("developers")
      group.gid.should eq("1001")
    end

    it "returns nil for a malformed line" do
      GroupState.parse("not-enough-fields").should be_nil
    end

    it "strips trailing whitespace/newline" do
      group = GroupState.parse("developers:x:1001:\n").as(GroupState::Group)
      group.gid.should eq("1001")
    end
  end

  describe ".groupadd_args" do
    it "includes -g when a gid is requested" do
      GroupState.groupadd_args("developers", "1001", false).should eq(["-g 1001", "developers"])
    end

    it "includes -r for a system group" do
      GroupState.groupadd_args("svc", nil, true).should eq(["-r", "svc"])
    end

    it "is just the name when nothing else is specified" do
      GroupState.groupadd_args("plain", nil, false).should eq(["plain"])
    end
  end

  describe ".groupmod_flags" do
    it "is empty when the gid already matches" do
      current = GroupState::Group.new("developers", "1001")
      GroupState.groupmod_flags(current, "1001").should eq([] of String)
    end

    it "is empty when no gid was requested" do
      current = GroupState::Group.new("developers", "1001")
      GroupState.groupmod_flags(current, nil).should eq([] of String)
    end

    it "requests -g when the gid differs" do
      current = GroupState::Group.new("developers", "1001")
      GroupState.groupmod_flags(current, "2002").should eq(["-g 2002"])
    end
  end
end

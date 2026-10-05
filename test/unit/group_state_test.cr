require "../minitest_helper"
require "../../src/krikri/plugin_helpers/group_state"

private alias GroupState = Krikri::PluginHelpers::GroupState

describe GroupState do
  describe ".parse" do
    it "parses a getent group line" do
      group = GroupState.parse("developers:x:1001:alice,bob").as(GroupState::Group)
      group.name.must_equal("developers")
      group.gid.must_equal("1001")
    end

    it "returns nil for a malformed line" do
      GroupState.parse("not-enough-fields").must_be_nil
    end

    it "strips trailing whitespace/newline" do
      group = GroupState.parse("developers:x:1001:\n").as(GroupState::Group)
      group.gid.must_equal("1001")
    end
  end

  describe ".local_parse" do
    it "finds the group's line in a full /etc/group listing" do
      group = GroupState.local_parse(<<-FILE, "adm")
        root:x:0:
        adm:x:4:labros
        sudo:x:27:
        FILE
      group.as(GroupState::Group).gid.must_equal("4")
    end

    it "prefers the LAST matching line (Ansible scans reversed lines)" do
      group = GroupState.local_parse(<<-FILE, "dup")
        dup:x:1000:
        other:x:1001:
        dup:x:2000:
        FILE
      group.as(GroupState::Group).gid.must_equal("2000")
    end

    it "returns nil when the name is not in the file" do
      GroupState.local_parse("root:x:0:\n", "nope").must_be_nil
    end
  end

  describe ".local_gid_conflict" do
    it "returns the owning group's name when the gid is taken by another group" do
      owner = GroupState.local_gid_conflict("root:x:0:\nadm:x:4:\n", "newgrp", "4")
      owner.must_equal("adm")
    end

    it "returns nil when the same group already owns the gid" do
      GroupState.local_gid_conflict("adm:x:4:\n", "adm", "4").must_be_nil
    end

    it "returns nil when the gid is free" do
      GroupState.local_gid_conflict("root:x:0:\n", "newgrp", "4711").must_be_nil
    end

    it "skips the check entirely for gid 0 (Ansible module's Python `if self.gid:` truthiness, live-verified)" do
      GroupState.local_gid_conflict("root:x:0:\n", "other", "0").must_be_nil
    end
  end

  describe ".groupadd_args" do
    it "includes -g when a gid is requested" do
      GroupState.groupadd_args("developers", "1001", false).must_equal(["-g '1001'", "'developers'"])
    end

    it "includes -r for a system group" do
      GroupState.groupadd_args("svc", nil, true).must_equal(["-r", "'svc'"])
    end

    it "is just the quoted name when nothing else is specified" do
      GroupState.groupadd_args("plain", nil, false).must_equal(["'plain'"])
    end

    it "nests -o immediately after -g and never without a gid (live-verified shape)" do
      GroupState.groupadd_args("g1", "1234", true, non_unique: true)
        .must_equal(["-g '1234'", "-o", "-r", "'g1'"])
      GroupState.groupadd_args("g1", nil, false, non_unique: true).must_equal(["'g1'"])
    end

    it "appends -K GID_MIN/GID_MAX pairs after the gid/-r flags (live-verified shape)" do
      GroupState.groupadd_args("g1", "1234", true, non_unique: true, gid_min: "500", gid_max: "1000")
        .must_equal(["-g '1234'", "-o", "-r", "-K 'GID_MIN=500'", "-K 'GID_MAX=1000'", "'g1'"])
      GroupState.groupadd_args("g1", nil, false, gid_min: "2000", gid_max: "2999")
        .must_equal(["-K 'GID_MIN=2000'", "-K 'GID_MAX=2999'", "'g1'"])
    end

    it "never emits the -K pairs on the local path" do
      GroupState.groupadd_args("g1", nil, false, gid_min: "500", gid_max: "1000", local: true)
        .must_equal(["'g1'"])
    end

    it "keeps -r on the local path (Ansible passes it to lgroupadd too, live-verified)" do
      GroupState.groupadd_args("g1", nil, true, local: true).must_equal(["-r", "'g1'"])
    end

    it "single-quotes every task-controlled value" do
      GroupState.groupadd_args("evil$(reboot)", "1;2", false)
        .must_equal(["-g '1;2'", "'evil$(reboot)'"])
    end
  end

  describe ".groupmod_flags" do
    it "is empty when the gid already matches" do
      current = GroupState::Group.new("developers", "1001")
      GroupState.groupmod_flags(current, "1001").must_equal([] of String)
    end

    it "is empty when no gid was requested" do
      current = GroupState::Group.new("developers", "1001")
      GroupState.groupmod_flags(current, nil).must_equal([] of String)
    end

    it "requests -g when the gid differs" do
      current = GroupState::Group.new("developers", "1001")
      GroupState.groupmod_flags(current, "2002").must_equal(["-g '2002'"])
    end

    it "adds -o only alongside an actual gid change (live-verified shape)" do
      current = GroupState::Group.new("root", "0")
      GroupState.groupmod_flags(current, "4711", non_unique: true).must_equal(["-g '4711'", "-o"])
      GroupState.groupmod_flags(current, "0", non_unique: true).must_equal([] of String)
      GroupState.groupmod_flags(current, nil, non_unique: true).must_equal([] of String)
    end
  end
end

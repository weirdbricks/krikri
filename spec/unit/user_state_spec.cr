require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/user_state"

private alias UserState = CrystalPlay::PluginHelpers::UserState

private SAMPLE_LINE = "alice:x:1001:1001:Alice Example:/home/alice:/bin/bash"
private SAMPLE_USER = UserState.parse(SAMPLE_LINE).as(UserState::User)

describe UserState do
  describe ".parse" do
    it "parses a getent passwd line" do
      user = SAMPLE_USER
      user.name.should eq("alice")
      user.uid.should eq("1001")
      user.gid.should eq("1001")
      user.comment.should eq("Alice Example")
      user.home.should eq("/home/alice")
      user.shell.should eq("/bin/bash")
    end

    it "returns nil for a malformed line" do
      UserState.parse("too:few:fields").should be_nil
    end
  end

  describe ".useradd_args" do
    it "includes only the flags that were specified" do
      args = UserState.useradd_args("bob", "1002", nil, nil, "/bin/zsh", nil, nil, false, true)
      args.should eq(["-u 1002", "-s /bin/zsh", "-m", "bob"])
    end

    it "uses -M when create_home is false" do
      args = UserState.useradd_args("bob", nil, nil, nil, nil, nil, nil, false, false)
      args.should eq(["-M", "bob"])
    end

    it "includes -r for a system account" do
      args = UserState.useradd_args("svc", nil, nil, nil, nil, nil, nil, true, false)
      args.should eq(["-r", "-M", "svc"])
    end

    it "includes supplementary groups and a quoted comment" do
      args = UserState.useradd_args("bob", nil, nil, "sudo,docker", nil, nil, "Bob Q", false, true)
      args.should eq(["-G sudo,docker", "-c \"Bob Q\"", "-m", "bob"])
    end
  end

  describe ".usermod_flags" do
    it "is empty when the desired state already matches" do
      current = SAMPLE_USER
      UserState.usermod_flags(current, "1001", "1001", "/bin/bash", "/home/alice", "Alice Example").should eq([] of String)
    end

    it "is empty when nothing was requested" do
      current = SAMPLE_USER
      UserState.usermod_flags(current, nil, nil, nil, nil, nil).should eq([] of String)
    end

    it "flags only the attributes that differ" do
      current = SAMPLE_USER
      flags = UserState.usermod_flags(current, "1001", "1001", "/bin/zsh", "/home/alice", "Alice Example")
      flags.should eq(["-s /bin/zsh"])
    end

    it "flags multiple differing attributes" do
      current = SAMPLE_USER
      flags = UserState.usermod_flags(current, "2002", "1001", "/bin/bash", "/home/alice2", "Alice Example")
      flags.should eq(["-u 2002", "-d /home/alice2"])
    end
  end

  describe ".userdel_args" do
    it "adds -r when the home directory should be removed too" do
      UserState.userdel_args("alice", true).should eq(["-r", "alice"])
    end

    it "is just the username otherwise" do
      UserState.userdel_args("alice", false).should eq(["alice"])
    end
  end
end

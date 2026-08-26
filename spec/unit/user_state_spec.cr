require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/user_state"

private alias UserState = CrystalPlay::PluginHelpers::UserState

private SAMPLE_LINE   = "alice:x:1001:1001:Alice Example:/home/alice:/bin/bash"
private SAMPLE_USER   = UserState.parse(SAMPLE_LINE).as(UserState::User)
private SHADOW_SAMPLE = "root:!:19900:0:99999:7:::\nalice:$6$abc$hash:19900:0:99999:7:::\n"

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

    it "omits a flag whose value is an empty string, not just nil" do
      # Real bug found benchmarking ansible-community.ansible-vault:
      # `groups: "{{ vault_groups }}"` where vault_groups: null renders
      # to the empty string "" (real Ansible's own format_value for
      # Nil), not nil - the old `if groups` check treated "" as truthy
      # (Crystal only treats nil/false as falsy), adding a value-less
      # "-G " flag. Joined into one shell command string with the
      # following flags, that shifted every subsequent token left by
      # one - the *next* flag's own name ("-c") got consumed as if it
      # were "-G"'s value, producing useradd's own confusing "group
      # '-c' does not exist".
      args = UserState.useradd_args("vault", nil, "bin", "", nil, nil, "Vault user", true, false)
      args.should eq(["-g bin", "-c \"Vault user\"", "-r", "-M", "vault"])
    end

    it "omits -G when groups renders to the empty-list text \"[]\"" do
      # Real bug found benchmarking andrewrothstein.gitlab_runner (round
      # 185): `groups: "{{ addl_groups | default([]) }}"` where
      # addl_groups is undefined renders through this codebase's own
      # non-native `{{ }}` substitution to the literal text "[]" (same
      # as Python's `str([])`), which `groups.presence` alone treats as
      # a real (single, malformed) group name - `useradd: group '[]'
      # does not exist`. Real Ansible's `groups:` argspec is `type:
      # list`, and `check_type_list` parses a `[...]`-shaped string back
      # into a real list via `ast.literal_eval` before ever reaching
      # useradd, so it passes no `-G` at all for an empty list.
      args = UserState.useradd_args("runner", nil, nil, "[]", nil, nil, nil, false, true)
      args.should eq(["-m", "runner"])
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

    it "does not flag an empty-string desired value as a change, matching useradd_args' same fix" do
      current = SAMPLE_USER
      UserState.usermod_flags(current, "", "", "", "", "").should eq([] of String)
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

  describe ".shadow_password" do
    it "extracts the hash field for a matching entry" do
      UserState.shadow_password(SHADOW_SAMPLE, "alice").should eq("$6$abc$hash")
    end

    it "extracts a locked ('!'-prefixed) entry verbatim" do
      UserState.shadow_password(SHADOW_SAMPLE, "root").should eq("!")
    end

    it "returns nil for an account with no shadow entry" do
      UserState.shadow_password(SHADOW_SAMPLE, "nobody").should be_nil
    end
  end

  describe ".password_matches?" do
    it "matches identical hashes" do
      UserState.password_matches?("$6$abc$hash", "$6$abc$hash").should be_true
    end

    it "ignores a leading ! lock-marker on either side" do
      UserState.password_matches?("!$6$abc$hash", "$6$abc$hash").should be_true
      UserState.password_matches?("$6$abc$hash", "!$6$abc$hash").should be_true
    end

    it "does not match a genuinely different hash" do
      UserState.password_matches?("$6$abc$hash", "$6$xyz$other").should be_false
    end
  end

  describe ".useradd_password_args" do
    it "is empty when no password is given" do
      UserState.useradd_password_args(nil, nil).should eq([] of String)
    end

    it "passes the hash straight through when not locked" do
      UserState.useradd_password_args("$6$abc$hash", nil).should eq(["-p", "$6$abc$hash"])
      UserState.useradd_password_args("$6$abc$hash", false).should eq(["-p", "$6$abc$hash"])
    end

    it "prefixes the hash with ! when password_lock: true" do
      UserState.useradd_password_args("$6$abc$hash", true).should eq(["-p", "!$6$abc$hash"])
    end
  end

  describe ".password_update_flags" do
    it "is empty when the desired hash already matches and no lock change is requested" do
      UserState.password_update_flags("$6$abc$hash", "$6$abc$hash", "always", nil).should eq([] of String)
    end

    it "updates the password when it differs and update_password: always (the default)" do
      UserState.password_update_flags("$6$old$hash", "$6$new$hash", "always", nil).should eq(["-p", "$6$new$hash"])
    end

    it "never touches an existing account's password when update_password: on_create" do
      UserState.password_update_flags("$6$old$hash", "$6$new$hash", "on_create", nil).should eq([] of String)
    end

    it "folds the lock marker into -p instead of emitting a separate -L when both are requested together" do
      UserState.password_update_flags("$6$old$hash", "$6$new$hash", "always", true).should eq(["-p", "!$6$new$hash"])
    end

    it "locks an already-correct, currently-unlocked password with -L" do
      UserState.password_update_flags("$6$abc$hash", nil, "always", true).should eq(["-L"])
    end

    it "unlocks a locked account with -U" do
      UserState.password_update_flags("!$6$abc$hash", nil, "always", false).should eq(["-U"])
    end

    it "does not re-lock an already-locked account" do
      UserState.password_update_flags("!$6$abc$hash", nil, "always", true).should eq([] of String)
    end

    it "does not re-unlock an already-unlocked account" do
      UserState.password_update_flags("$6$abc$hash", nil, "always", false).should eq([] of String)
    end
  end

  describe ".expires_date" do
    # Real bug found via a proactive scope-cut audit: expires: was
    # entirely unimplemented. Verified against real python's own
    # `time.strftime('%Y-%m-%d', time.gmtime(timestamp))` output
    # directly for the same inputs, not assumed.
    it "matches Python's own time.gmtime + strftime output exactly" do
      UserState.expires_date(1422403387_i64).should eq("2015-01-28")
      UserState.expires_date(0_i64).should eq("1970-01-01")
    end

    it "returns an empty string for a negative timestamp (real Ansible's own '-1 to remove' convention)" do
      UserState.expires_date(-1_i64).should eq("")
    end
  end

  describe ".expires_changed?" do
    it "is false when the requested timestamp maps to the same calendar day already set" do
      # 2015-01-28 00:00:00 UTC and 2015-01-28 23:59:59 UTC are the same
      # day-since-epoch (16463) - real Ansible's own usermod-path
      # comparison is day-level, not full-timestamp.
      UserState.expires_changed?(1422403387_i64, 16463).should be_false
    end

    it "is true when the requested day differs from what's currently set" do
      UserState.expires_changed?(1422403387_i64, 16000).should be_true
    end

    it "is true when nothing is currently set" do
      UserState.expires_changed?(1422403387_i64, nil).should be_true
    end

    it "treats a negative (remove) timestamp as unchanged only when nothing is currently set" do
      UserState.expires_changed?(-1_i64, nil).should be_false
      UserState.expires_changed?(-1_i64, 16463).should be_true
    end
  end
end

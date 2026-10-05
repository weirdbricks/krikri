require "../minitest_helper"
require "../../src/krikri/plugin_helpers/user_state"

private alias UserState = Krikri::PluginHelpers::UserState

private SAMPLE_LINE   = "alice:x:1001:1001:Alice Example:/home/alice:/bin/bash"
private SAMPLE_USER   = UserState.parse(SAMPLE_LINE).as(UserState::User)
private SHADOW_SAMPLE = "root:!:19900:0:99999:7:::\nalice:$6$abc$hash:19900:0:99999:7:::\n"

describe UserState do
  describe ".parse" do
    it "parses a getent passwd line" do
      user = SAMPLE_USER
      user.name.must_equal("alice")
      user.uid.must_equal("1001")
      user.gid.must_equal("1001")
      user.comment.must_equal("Alice Example")
      user.home.must_equal("/home/alice")
      user.shell.must_equal("/bin/bash")
    end

    it "returns nil for a malformed line" do
      UserState.parse("too:few:fields").must_be_nil
    end
  end

  describe ".useradd_args" do
    it "includes only the flags that were specified" do
      args = UserState.useradd_args("bob", "1002", nil, nil, "/bin/zsh", nil, nil, false, true)
      args.must_equal(["-u '1002'", "-s '/bin/zsh'", "-m", "'bob'"])
    end

    it "uses -M when create_home is false" do
      args = UserState.useradd_args("bob", nil, nil, nil, nil, nil, nil, false, false)
      args.must_equal(["-M", "'bob'"])
    end

    it "includes -r for a system account" do
      args = UserState.useradd_args("svc", nil, nil, nil, nil, nil, nil, true, false)
      args.must_equal(["-r", "-M", "'svc'"])
    end

    it "includes supplementary groups and a quoted comment" do
      args = UserState.useradd_args("bob", nil, nil, "sudo,docker", nil, nil, "Bob Q", false, true)
      args.must_equal(["-G 'sudo,docker'", "-c 'Bob Q'", "-m", "'bob'"])
    end

    it "omits a flag whose value is an empty string, not just nil" do
      # Real bug found benchmarking ansible-community.ansible-vault:
      # `groups: "{{ vault_groups }}"` where vault_groups: null renders
      # to the empty string "" (Ansible's own format_value for
      # Nil), not nil - the old `if groups` check treated "" as truthy
      # (Crystal only treats nil/false as falsy), adding a value-less
      # "-G " flag. Joined into one shell command string with the
      # following flags, that shifted every subsequent token left by
      # one - the *next* flag's own name ("-c") got consumed as if it
      # were "-G"'s value, producing useradd's own confusing "group
      # '-c' does not exist".
      args = UserState.useradd_args("vault", nil, "bin", "", nil, nil, "Vault user", true, false)
      args.must_equal(["-g 'bin'", "-c 'Vault user'", "-r", "-M", "'vault'"])
    end

    it "omits -G when groups renders to the empty-list text \"[]\"" do
      # Real bug found benchmarking andrewrothstein.gitlab_runner (round
      # 185): `groups: "{{ addl_groups | default([]) }}"` where
      # addl_groups is undefined renders through this codebase's own
      # non-native `{{ }}` substitution to the literal text "[]" (same
      # as Python's `str([])`), which `groups.presence` alone treats as
      # a real (single, malformed) group name - `useradd: group '[]'
      # does not exist`. Ansible's `groups:` argspec is `type:
      # list`, and `check_type_list` parses a `[...]`-shaped string back
      # into a real list via `ast.literal_eval` before ever reaching
      # useradd, so it passes no `-G` at all for an empty list.
      args = UserState.useradd_args("runner", nil, nil, "[]", nil, nil, nil, false, true)
      args.must_equal(["-m", "'runner'"])
    end

    it "comma-joins a multi-item JSON-array groups: value instead of passing the bracket text raw to -G" do
      # Real bug found benchmarking kostiantyn-nemchenko.mongodb_exporter's
      # own `groups: "{{ mongodb_exporter_system_groups }}"` (a full-value
      # substitution of a real 2-item list) - the templated-list wire
      # format is the double-quoted JSON text
      # substitute_task_params's whole-single-span comment documents,
      # and passing the raw bracketed string straight to `-G` made
      # useradd itself split on the comma INSIDE the quotes, producing
      # two bogus group names ("['mongodb_exporter'" and " 'ssl-cert']")
      # and failing "group ... does not exist" for both.
      args = UserState.useradd_args("mongodb_exporter", nil, nil, %(["mongodb_exporter", "ssl-cert"]), nil, nil, nil, false, true)
      args.must_equal(["-G 'mongodb_exporter,ssl-cert'", "-m", "'mongodb_exporter'"])
    end

    it "passes a Python-repr-looking groups: string through raw (never re-parsed into a list)" do
      # ansible-core's native typing requires a template's whole
      # parsed AST to be exactly one output node wrapping one
      # expression, so a value that merely LOOKS like a container - a
      # literal `groups: "['a', 'b']"` string, or a `{% if %}...{% else
      # %}['a']{% endif %}` block's rendered output - is a plain STRING
      # (live-verified vs ansible-playbook 2.19.11 for the same bug
      # class on apt's name:). The single-quote "repair" this spec used
      # to assert turned that string into a real group list real
      # Ansible never had; passing the raw text to `-G` now fails with
      # useradd's own "group ... does not exist" exactly like real
      # Ansible's comma-split garbage does.
      args = UserState.useradd_args("mongodb_exporter", nil, nil, "['mongodb_exporter', 'ssl-cert']", nil, nil, nil, false, true)
      args.must_equal(["-G '['\\''mongodb_exporter'\\'', '\\''ssl-cert'\\'']'", "-m", "'mongodb_exporter'"])
    end

    it "emits -o alongside the uid when non_unique is set (live-verified: `useradd -u 60000 -o ...`)" do
      args = UserState.useradd_args("dup", "60000", nil, nil, nil, nil, nil, false, true, non_unique: true)
      args.must_equal(["-u '60000'", "-o", "-m", "'dup'"])
    end

    it "never emits -o without a uid (Ansible nests it inside its own uid branch)" do
      args = UserState.useradd_args("dup", nil, nil, nil, nil, nil, nil, false, true, non_unique: true)
      args.must_equal(["-m", "'dup'"])
    end

    it "passes skeleton/umask as -k/-K UMASK inside the create_home branch and -f for password_expire_account_disable" do
      # Live-verified against ansible-core 2.19.4's create_user_useradd
      # via shimmed useradd: `useradd -u 60000 -o -e 2030-01-01 -f 30
      # -m -k /etc/skel.custom -K UMASK=027 <name>`.
      args = UserState.useradd_args("sk", "60000", nil, nil, nil, "/home/sk", nil, false, true,
        non_unique: true, skeleton: "/etc/skel.custom", umask: "027", inactive: "30")
      args.must_equal(["-u '60000'", "-o", "-d '/home/sk'", "-m", "-k '/etc/skel.custom'", "-K 'UMASK=027'", "-f '30'", "'sk'"])
    end

    it "silently drops skeleton/umask when create_home is off (Ansible ignores them there too)" do
      args = UserState.useradd_args("sk", nil, nil, nil, nil, "/home/sk", nil, false, false,
        skeleton: "/etc/skel.custom", umask: "027")
      args.must_equal(["-d '/home/sk'", "-M", "'sk'"])
    end

    it "keeps -k/-K/-f but drops -m and -G on the local (luseradd) path" do
      # Live-verified: `luseradd -f 30 -k /etc/skel.custom <name>` - no
      # -m, no -G (libuser has neither; groups/expiry go through the
      # lgroupmod/lchage tail instead).
      args = UserState.useradd_args("loc", nil, nil, "adm", nil, "/home/loc", nil, false, true,
        skeleton: "/etc/skel.custom", inactive: "30", local: true)
      args.must_equal(["-d '/home/loc'", "-k '/etc/skel.custom'", "-f '30'", "'loc'"])
    end
  end

  describe ".usermod_flags" do
    it "is empty when the desired state already matches" do
      current = SAMPLE_USER
      UserState.usermod_flags(current, "1001", "1001", "/bin/bash", "/home/alice", "Alice Example").must_equal([] of String)
    end

    it "is empty when nothing was requested" do
      current = SAMPLE_USER
      UserState.usermod_flags(current, nil, nil, nil, nil, nil).must_equal([] of String)
    end

    it "flags only the attributes that differ" do
      current = SAMPLE_USER
      flags = UserState.usermod_flags(current, "1001", "1001", "/bin/zsh", "/home/alice", "Alice Example")
      flags.must_equal(["-s '/bin/zsh'"])
    end

    it "flags multiple differing attributes" do
      current = SAMPLE_USER
      flags = UserState.usermod_flags(current, "2002", "1001", "/bin/bash", "/home/alice2", "Alice Example")
      flags.must_equal(["-u '2002'", "-d '/home/alice2'"])
    end

    it "does not flag an empty-string desired value as a change, matching useradd_args' same fix" do
      current = SAMPLE_USER
      UserState.usermod_flags(current, "", "", "", "", "").must_equal([] of String)
    end

    it "emits -o after a changing uid when non_unique is set (live-verified: `usermod -u 60001 -o ...`)" do
      flags = UserState.usermod_flags(SAMPLE_USER, "60001", nil, nil, nil, nil, non_unique: true)
      flags.must_equal(["-u '60001'", "-o"])
    end

    it "emits -m right after -d when move_home is set and the home is changing" do
      flags = UserState.usermod_flags(SAMPLE_USER, nil, nil, nil, "/home/alice2", nil, move_home: true)
      flags.must_equal(["-d '/home/alice2'", "-m"])
    end

    it "never emits -m when the home is not changing, even with move_home set" do
      UserState.usermod_flags(SAMPLE_USER, nil, nil, nil, "/home/alice", nil, move_home: true).must_equal([] of String)
    end

    it "emits -f for password_expire_account_disable even when everything else already matches (Ansible has no idempotency check for it)" do
      flags = UserState.usermod_flags(SAMPLE_USER, nil, nil, nil, nil, nil, inactive: "30")
      flags.must_equal(["-f '30'"])
    end
  end

  describe ".userdel_args" do
    it "adds -r when the home directory should be removed too" do
      UserState.userdel_args("alice", true).must_equal(["-r", "'alice'"])
    end

    it "is just the username otherwise" do
      UserState.userdel_args("alice", false).must_equal(["'alice'"])
    end
  end

  describe ".shadow_password" do
    it "extracts the hash field for a matching entry" do
      UserState.shadow_password(SHADOW_SAMPLE, "alice").must_equal("$6$abc$hash")
    end

    it "extracts a locked ('!'-prefixed) entry verbatim" do
      UserState.shadow_password(SHADOW_SAMPLE, "root").must_equal("!")
    end

    it "returns nil for an account with no shadow entry" do
      UserState.shadow_password(SHADOW_SAMPLE, "nobody").must_be_nil
    end
  end

  describe ".password_matches?" do
    it "matches identical hashes" do
      UserState.password_matches?("$6$abc$hash", "$6$abc$hash").must_equal(true)
    end

    it "ignores a leading ! lock-marker on either side" do
      UserState.password_matches?("!$6$abc$hash", "$6$abc$hash").must_equal(true)
      UserState.password_matches?("$6$abc$hash", "!$6$abc$hash").must_equal(true)
    end

    it "does not match a genuinely different hash" do
      UserState.password_matches?("$6$abc$hash", "$6$xyz$other").must_equal(false)
    end
  end

  describe ".useradd_password_args" do
    it "is empty when no password is given" do
      UserState.useradd_password_args(nil, nil).must_equal([] of String)
    end

    it "passes the hash straight through when not locked" do
      UserState.useradd_password_args("$6$abc$hash", nil).must_equal(["-p", "$6$abc$hash"])
      UserState.useradd_password_args("$6$abc$hash", false).must_equal(["-p", "$6$abc$hash"])
    end

    it "prefixes the hash with ! when password_lock: true" do
      UserState.useradd_password_args("$6$abc$hash", true).must_equal(["-p", "!$6$abc$hash"])
    end
  end

  describe ".password_update_flags" do
    it "is empty when the desired hash already matches and no lock change is requested" do
      UserState.password_update_flags("$6$abc$hash", "$6$abc$hash", "always", nil).must_equal([] of String)
    end

    it "updates the password when it differs and update_password: always (the default)" do
      UserState.password_update_flags("$6$old$hash", "$6$new$hash", "always", nil).must_equal(["-p", "$6$new$hash"])
    end

    it "never touches an existing account's password when update_password: on_create" do
      UserState.password_update_flags("$6$old$hash", "$6$new$hash", "on_create", nil).must_equal([] of String)
    end

    it "folds the lock marker into -p instead of emitting a separate -L when both are requested together" do
      UserState.password_update_flags("$6$old$hash", "$6$new$hash", "always", true).must_equal(["-p", "!$6$new$hash"])
    end

    it "locks an already-correct, currently-unlocked password with -L" do
      UserState.password_update_flags("$6$abc$hash", nil, "always", true).must_equal(["-L"])
    end

    it "unlocks a locked account with -U" do
      UserState.password_update_flags("!$6$abc$hash", nil, "always", false).must_equal(["-U"])
    end

    it "does not re-lock an already-locked account" do
      UserState.password_update_flags("!$6$abc$hash", nil, "always", true).must_equal([] of String)
    end

    it "does not re-unlock an already-unlocked account" do
      UserState.password_update_flags("$6$abc$hash", nil, "always", false).must_equal([] of String)
    end
  end

  describe ".expires_date" do
    # Real bug found via a proactive scope-cut audit: expires: was
    # entirely unimplemented. Verified against real python's own
    # `time.strftime('%Y-%m-%d', time.gmtime(timestamp))` output
    # directly for the same inputs, not assumed.
    it "matches Python's own time.gmtime + strftime output exactly" do
      UserState.expires_date(1422403387_i64).must_equal("2015-01-28")
      UserState.expires_date(0_i64).must_equal("1970-01-01")
    end

    it "returns an empty string for a negative timestamp (Ansible's own '-1 to remove' convention)" do
      UserState.expires_date(-1_i64).must_equal("")
    end
  end

  describe ".expires_changed?" do
    it "is false when the requested timestamp maps to the same calendar day already set" do
      # 2015-01-28 00:00:00 UTC and 2015-01-28 23:59:59 UTC are the same
      # day-since-epoch (16463) - Ansible's own usermod-path
      # comparison is day-level, not full-timestamp.
      UserState.expires_changed?(1422403387_i64, 16463).must_equal(false)
    end

    it "is true when the requested day differs from what's currently set" do
      UserState.expires_changed?(1422403387_i64, 16000).must_equal(true)
    end

    it "is true when nothing is currently set" do
      UserState.expires_changed?(1422403387_i64, nil).must_equal(true)
    end

    it "treats a negative (remove) timestamp as unchanged only when nothing is currently set" do
      UserState.expires_changed?(-1_i64, nil).must_equal(false)
      UserState.expires_changed?(-1_i64, 16463).must_equal(true)
    end
  end

  describe ".local_expiry_days" do
    # Live-verified against the Ansible module's local branch: expires:
    # 1893456000 emits `lchage -E 21915` (whole days since epoch,
    # unlike the normal path's `-e YYYY-MM-DD`).
    it "converts a timestamp to whole days since epoch" do
      UserState.local_expiry_days(1893456000_i64).must_equal(21915)
    end

    it "maps a negative (remove) timestamp to lchage's own -1 clear value" do
      UserState.local_expiry_days(-1_i64).must_equal(-1)
    end
  end
end

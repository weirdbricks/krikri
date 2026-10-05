#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/user_state"

module Krikri
  # User plugin - manages a system account via getent/useradd/usermod/userdel
  # Compatible with (a subset of) Ansible's ansible.builtin.user module
  #
  # Parameters:
  #   name (required)
  #   state (optional): present (default) or absent
  #   uid, group (primary gid/group name), groups (supplementary, comma
  #     separated), shell, home, comment (optional)
  #   system (optional, default no): pass -r to useradd
  #   create_home (optional, default yes)
  #   remove (optional, default no): pass -r to userdel (also remove home dir)
  #   password: an *already-hashed* password (this codebase never hashes
  #     a cleartext value itself, matching Ansible's own requirement
  #     - `mkpasswd --method=sha-512`/`openssl passwd` are the usual way
  #     to produce one). Applied via `useradd -p`/`usermod -p`, matching
  #     Ansible's own command shape exactly (verified against its
  #     actual `create_user_useradd`/`modify_user_usermod` source, not
  #     assumed) - `password_lock: true` prefixes the hash with `!`,
  #     `usermod`'s own lock-account convention.
  #     SECURITY NOTE (deliberate, compatibility-preserving): the hash
  #     rides argv, so it is briefly visible in the target's process
  #     list - Ansible's own module execs useradd/usermod the same
  #     way (argv list, hash included), so this parity is kept rather
  #     than switching to a chpasswd/stdin form that would change the
  #     command shape and result semantics.
  #   update_password (optional, default "always"): "always" reissues
  #     `-p` whenever the given hash doesn't match what's already in
  #     `/etc/shadow` for an *existing* account; "on_create" only ever
  #     applies `password:` at creation time, never touching an existing
  #     account's password - matches Ansible's own two allowed
  #     values and default exactly. Like this codebase's own
  #     `mysql_user.cr`, this can't compare a *candidate cleartext*
  #     password to a stored hash - the caller is always expected to
  #     already have a hash, same as Ansible itself requires, so
  #     "unchanged" means "the given hash already matches what's stored,"
  #     not "the account's password is already this."
  #   password_lock (optional, bool): locks/unlocks the account via
  #     `usermod -L`/`-U` (or folded into `-p '!hash'` instead when
  #     combined with a real password change in the same run, matching
  #     Ansible's own mutual-exclusion between `-p` and `-L`/`-U`)
  #
  #   expires (optional): account expiration, a Unix TIMESTAMP (seconds,
  #     NOT days) - verified against the Ansible module's own
  #     source: converted to a `YYYY-MM-DD` UTC date via `-e` on
  #     useradd/usermod; a negative value (Ansible's own documented
  #     "-1 to remove" convention) clears the expiration (`-e ''`).
  #     Idempotency compares whole days-since-epoch against `/etc/
  #     shadow`'s own expire field (field 8), matching Ansible's
  #     own day-level (not full-timestamp) comparison exactly - a value
  #     that maps to the same calendar day as what's already set is a
  #     no-op.
  #   generate_ssh_key (optional, bool): after create/modify, generate a
  #     private/public keypair for the account via ssh-keygen when it does
  #     not exist yet - ssh_key_type (default rsa), ssh_key_file (default
  #     `.ssh/id_<type>`, relative paths resolved against the account's
  #     home), ssh_key_bits, ssh_key_comment, ssh_key_passphrase, force
  #     (overwrite an existing key). Mirrors ansible-core user.py's
  #     own ssh_key_gen: the .ssh dir is created 0700 and chowned to the
  #     account, an already-existing private OR public key file is a
  #     no-op unless force:, and a relative ssh_key_file against a home
  #     that does not exist fails the task (verified against 2.19.4's
  #     source and live run - abaez.user's own `create a user ssh_key`
  #     task, round 84001: previously the params were never even read, so
  #     the key was never generated and the task always reported ok).
  #
  #   password_expire_account_disable (optional, int): days after a
  #     password expires before the account is permanently disabled -
  #     NOT a chage param despite looking like one: Ansible's own
  #     create_user_useradd/modify_user_usermod pass it as useradd/
  #     usermod's `-f <days>` (live-verified against ansible-core
  #     2.19.4: `useradd -f 30 ...` / `usermod ... -f 30 <name>`),
  #     independent of `expires:`'s `-e`. Ansible has no
  #     idempotency comparison for it, so giving it re-issues `-f` (and
  #     reports changed) on every run - replicated.
  #   skeleton (optional): custom skeleton directory passed as useradd
  #     `-k <dir>` at creation (only when create_home is on -
  #     Ansible ignores it silently otherwise), and used as the copy
  #     source when the modify path has to create a relocated home (Ansible's own create_homedir: skeleton: if given, else
  #     /etc/skel).
  #   move_home (optional, default no): with `home:` changing on an
  #     existing account, pass usermod's `-m` too (move the old home's
  #     contents to the new location) - Ansible only ever emits
  #     `-m` alongside an actual `-d` change, never on its own.
  #   non_unique (optional, default no): allow a duplicate uid -
  #     useradd/usermod `-o`, only ever emitted together with a uid
  #     that is being set (create) or changed (modify), matching
  #     Ansible's own nesting of `-o` inside its uid branch.
  #   local (optional, default no): operate on the local account files
  #     only, bypassing NSS - existence is checked by reading
  #     /etc/passwd directly (never `getent`, which would find a
  #     directory/SSSD/LDAP account), and all work goes through the
  #     libuser tools (luseradd/lusermod/luserdel/lgroupmod/lchage)
  #     instead of shadow-utils, with Ansible's own per-tool
  #     differences (no -m, no -G, `-n` instead of `-N`, expiry via
  #     `lchage -E <days>`). Fails with Ansible's own message when
  #     combined with `umask:` ('umask' can not be used with 'local').
  #   umask (optional): controls the new home directory's permission
  #     mode at creation - passed as useradd `-K UMASK=<umask>` (only
  #     when create_home is on). NOTE: Ansible only threads it
  #     through useradd this way; its own modify-path home creation
  #     derives the mode from /etc/login.defs, not this param.
  #
  # Out of scope (deliberately, this is a Linux-only engine - these are
  # BSD/macOS/SELinux-only options of the Ansible module and are rejected
  # by the platforms krikri targets): login_class, seuser, hidden,
  # authorization, role, profile.
  #
  # Not implemented: any password-strength/format validation or warning
  # (Ansible's own `check_password_encrypted` only ever warns, never
  # fails, on a value that doesn't look hashed - this plugin passes
  # `password:` straight through either way).
  class UserPlugin < BasePlugin
    # Registered-result key order (live-verified vs ansible-core 2.19.11 on
    # Ubuntu 22.04, round 992000 + local container replay of every probe):
    # user.py main() builds result = {name, state} first, then the per-path
    # params (create: system/create_home; modify: append/move_home; both
    # BEFORE the password echo), then changed, then stdout/stderr from the
    # useradd/usermod call, then the resolved user facts (uid, group,
    # comment, home, shell), then groups/ssh-key fields. The *_lines keys
    # are appended by the ACTION plugin after every module key, and the
    # executor backfills failed last. Real success results carry NO msg.
    USER_CREATE_ORDER = ["name", "state", "system", "create_home", "password", "changed",
                         "stdout", "stderr", "uid", "group", "comment", "home", "shell",
                         "groups", "ssh_fingerprint", "ssh_key_file", "ssh_public_key",
                         "stdout_lines", "stderr_lines"]
    USER_MODIFY_ORDER = ["name", "state", "append", "move_home", "password", "changed",
                         "stdout", "stderr", "uid", "group", "comment", "home", "shell",
                         "groups", "ssh_fingerprint", "ssh_key_file", "ssh_public_key",
                         "stdout_lines", "stderr_lines"]
    # state=absent after a real removal: name/state, force/remove (only
    # when an account was actually removed), changed, then the userdel
    # out/err, then the action-plugin *_lines.
    USER_ABSENT_REMOVED_ORDER = ["name", "state", "force", "remove", "changed",
                                 "stdout", "stderr", "stdout_lines", "stderr_lines"]
    USER_ABSENT_ORDER = ["name", "state", "changed"]
    # check-mode early exit_json(changed=True) - nothing else (create of a
    # missing user, removal of an existing one).
    USER_CHECK_ONLY_ORDER = ["changed"]
    # fail_json(name=self.name, msg=err, rc=rc): the kwargs lead in call
    # order, then the fail_json backfill (failed, msg), changed, exception.
    USER_CMD_FAIL_ORDER = ["name", "rc", "failed", "msg", "changed", "exception"]

    # ansible.builtin.user's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.user). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[append create_home force generate_ssh_key hidden local move_home non_unique
        password_lock remove system]
    end

    protected def bool_param_aliases : Hash(String, String)
      {
        "createhome" => "create_home",
      }
    end

    # These default to None in Ansible's argspec, so an explicit null
    # skips type validation there (see BasePlugin#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[hidden password_lock]
    end

    def execute : PluginResult
      result = execute_inner
      # user.py warns (deprecation-style) when append is set without groups
      if true?(@params["append"]?) && @params["groups"]?.to_s.strip.empty? && @params["groups"]?.to_s != "[]"
        existing = result.extra["warnings"]?.try(&.as_a?) || [] of JSON::Any
        result.extra["warnings"] = JSON::Any.new(existing + [JSON::Any.new("'append' is set, but no 'groups' are specified. Use 'groups' for appending new groups.This will change to an error in Ansible 2.14.")])
      end
      result
    end

    def execute_inner : PluginResult
      # Ansible.builtin.user's argument_spec declares `name` with
      # alias `user` (`name=dict(type='str', required=True,
      # aliases=['user'])`) - RedHatOfficial.rhel9_pci_dss (round 812000)
      # writes `user: '{{ item }}'` throughout its whole STIG role, which
      # Ansible resolves fine via that alias; this plugin only ever
      # read `name`, failing "Missing required parameter: name" on every
      # such task despite the alias spelling being given. Present alias
      # overwrites canonical, matching Ansible's own _handle_aliases
      # order (same convention plugins/cron.cr's `value`->`job` alias and
      # yum_repository.cr already follow).
      if user_alias = @params["user"]?
        @params["name"] = user_alias
      end

      name = @params["name"]?
      return missing_param("name") unless name

      # Bool-typed params: AnsibleModule type-converts them at module
      # setup, after the required-args/alias-resolution gates above - now
      # via the shared BasePlugin#validate_bool_params! (see its block
      # comment).
      validate_bool_params!

      # Ansible's own __init__ check, exact message (live-verified:
      # `ansible localhost -m user -a 'name=x umask=027 local=true'`
      # fails with this before anything else runs).
      if local? && @params["umask"]?.presence
        return PluginResult.new(changed: false, failed: true,
          msg: "'umask' can not be used with 'local'")
      end

      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)
      current = lookup(name)

      if state == "absent"
        ensure_absent(name, current, check_mode)
      else
        ensure_present(name, current, check_mode)
      end
    end

    # `local: true` bypasses NSS for the existence check: Ansible's
    # own user_exists() reads /etc/passwd directly there (its own comment:
    # "pwd ... cannot be used to determine whether or not an account
    # exists locally"), because `getent` would happily report a
    # directory/SSSD/LDAP account that the libuser tools cannot touch.
    private def lookup(name : String) : PluginHelpers::UserState::User?
      if local?
        result = remote_exec("cat /etc/passwd")
        return nil unless result[:exit_code] == 0
        line = result[:stdout].each_line.find(&.starts_with?("#{name}:"))
        return nil unless line
        return PluginHelpers::UserState.parse(line)
      end

      result = remote_exec("getent passwd #{shell_single_quote(name)}")
      return nil unless result[:exit_code] == 0
      PluginHelpers::UserState.parse(result[:stdout])
    end

    private def local? : Bool
      true?(@params["local"]?)
    end

    private def ensure_absent(name : String, current : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult
      unless current
        # Ansible echoes name/state (with changed: false) even for
        # an account that doesn't exist - its main() sets both
        # unconditionally before the state branches run.
        absent = PluginResult.new(changed: false, failed: false, key_order: USER_ABSENT_ORDER)
        attach_user_identity(absent, name, "absent")
        return absent
      end

      # Ansible exits with bare exit_json(changed=True) in check mode - before
      # force/remove and any echo: the registered shape is just [changed,
      # failed] (main()'s name/state never make it into the early exit).
      return PluginResult.new(changed: true, failed: false, key_order: USER_CHECK_ONLY_ORDER) if check_mode

      args = PluginHelpers::UserState.userdel_args(name, true?(@params["remove"]?))
      result = remote_exec("#{local? ? "luserdel" : "userdel"} #{args.join(" ")}")
      return command_failure("remove user", result) unless result[:exit_code] == 0
      invalidate_shadow_cache

      # ansible-core user.py's own state=absent result: name/state
      # echoed always, plus force/remove only when an existing account
      # was actually removed (live-verified result shape: no uid/home/
      # shell after a userdel - the account no longer exists to look up).
      # The userdel out/err ride along when non-empty (real: `if out:` /
      # `if err:`), with the *_lines keys alongside (the executor's
      # central augmentation overwrites them in place, keeping position).
      removed = PluginResult.new(changed: true, failed: false, key_order: USER_ABSENT_REMOVED_ORDER)
      attach_user_identity(removed, name, "absent")
      removed.extra["force"] = JSON::Any.new(true?(@params["force"]?))
      removed.extra["remove"] = JSON::Any.new(true?(@params["remove"]?))
      attach_command_output(removed, result[:stdout], result[:stderr])
      removed
    end

    private def ensure_present(name : String, current : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult
      state = @params["state"]? || "present"
      # Real user.py's create branch exits with bare exit_json(changed=True)
      # in check mode BEFORE anything else runs - no name/state echo, no
      # facts, no ageing/ssh-key tail (registered shape: [changed, failed]).
      # The modify branch has no such early exit (modify_user is check-mode
      # aware) and registers the full shape below.
      if current.nil? && check_mode
        return PluginResult.new(changed: true, failed: false, key_order: USER_CHECK_ONLY_ORDER)
      end

      base = current ? modify(name, current, check_mode) : create(name, check_mode)
      return base if base.failed?

      ageing = apply_password_ageing(name, check_mode)
      return ageing if ageing && ageing.failed?

      # Ansible's user module ALWAYS returns the resolved user
      # facts (home/uid/group/shell/name) in its register result -
      # whether the user was just created, just modified, or already
      # matched. Re-reads the FINAL state (post create/modify - one
      # cheap extra `getent passwd`, check_mode has no real state to
      # read so it's skipped) rather than reusing the pre-task
      # `current`, which Ansible also does (a create/modify may
      # have changed exactly the field a later task wants to read).
      # Missing entirely before - found via konstruktoid.docker_rootless's
      # own `register: docker_user_info` followed by `{{
      # docker_user_info.home }}`, undefined regardless of whether the
      # user already existed.
      facts = check_mode ? current : lookup(name)

      # Ansible's main() runs ssh_key_gen after create/modify alike
      # (its own common tail, not inside either branch).
      ssh_key = apply_ssh_key(name, facts, check_mode)
      return ssh_key if ssh_key && ssh_key.failed?

      result = PluginResult.new(
        changed: combine_changed?(base, ageing, ssh_key),
        failed: false,
        key_order: current ? USER_MODIFY_ORDER : USER_CREATE_ORDER
      )
      attach_user_facts(result, facts) if facts
      attach_command_output(result, base.extra["stdout"]?.try(&.as_s) || "", base.extra["stderr"]?.try(&.as_s) || "")

      # ansible-core user.py's own result keys beyond the resolved
      # identity (verified against its main() result assembly and live
      # `ansible localhost -c local -m user` runs):
      # - name/state are ALWAYS echoed (even state=absent)
      # - append/move_home only on the modify-existing-account path
      # - system/create_home only on the create path
      # - groups (the comma-joined param) only when groups: was given
      # - password: 'NOT_LOGGING_PASSWORD' only when password: was given
      attach_user_identity(result, name, state)
      if current
        result.extra["append"] = JSON::Any.new(true?(@params["append"]?))
        result.extra["move_home"] = JSON::Any.new(true?(@params["move_home"]?))
      else
        result.extra["system"] = JSON::Any.new(true?(@params["system"]?))
        result.extra["create_home"] = JSON::Any.new(wants_create_home?)
      end
      if groups = @params["groups"]?.presence
        result.extra["groups"] = JSON::Any.new(groups)
      end
      if @params["password"]?.presence
        result.extra["password"] = JSON::Any.new("NOT_LOGGING_PASSWORD")
      end
      # apply_ssh_key's own ssh_key_file/ssh_public_key/ssh_fingerprint
      # fields (Ansible's own returned keys for generate_ssh_key:)
      # live on ITS PluginResult, not the merged one built above - never
      # copied over, so a task registering the result and reading `{{
      # user_result.ssh_public_key }}` always saw it undefined even
      # though the key genuinely generated.
      ssh_key.try(&.extra.each { |k, v| result.extra[k] = v })
      result
    end

    private def combine_changed?(base : PluginResult, ageing : PluginResult?, ssh_key : PluginResult?) : Bool
      base.changed? || (ageing.try(&.changed?) || false) || (ssh_key.try(&.changed?) || false)
    end

    # Real user.py: `if out: result['stdout'] = out` / `if err: result['stderr']
    # = err` - the raw useradd/usermod/userdel output rides the result only
    # when non-empty, with the paired *_lines key alongside (the executor's
    # central command-lines augmentation overwrites the value in place,
    # keeping the position Ansible's action plugin gives it: after every
    # module key, before the executor's failed backfill).
    private def attach_command_output(result : PluginResult, stdout : String, stderr : String) : Nil
      if !stdout.empty?
        result.extra["stdout"] = JSON::Any.new(stdout)
        result.extra["stdout_lines"] = JSON::Any.new(stdout.lines.to_a.map { |entry| JSON::Any.new(entry) })
      end
      if !stderr.empty?
        result.extra["stderr"] = JSON::Any.new(stderr)
        result.extra["stderr_lines"] = JSON::Any.new(stderr.lines.to_a.map { |entry| JSON::Any.new(entry) })
      end
    end

    # generate_ssh_key: + friends - ansible-core user.py's own
    # ssh_key_gen (Linux useradd path), called from main()'s common tail
    # AFTER create/modify alike. Generates the account's private/public
    # keypair via ssh-keygen when it does not exist yet:
    #
    # - ssh_key_file (default `.ssh/id_<ssh_key_type>`) is resolved
    #   against the account's home directory when relative; a home that
    #   does not exist is a task failure (Ansible's own
    #   get_ssh_key_path raise, non-check mode only).
    # - The key's parent dir is created 0700 and chowned to the account
    #   when missing (Ansible's own os.mkdir/os.chown).
    # - An existing private OR public key file is a no-op unless force:
    #   overwrites it; in check mode any would-be generation reports
    #   changed without touching anything.
    # - On success the pair is chowned to the account and the register
    #   result carries ssh_key_file/ssh_public_key/ssh_fingerprint,
    #   matching Ansible's own returned fields.
    # Resolves ssh_key_file: against the account's home when relative -
    # Ansible's own get_ssh_key_path, including its home-must-exist
    # failure (non-check-mode only). Returns {key_path, nil} on success,
    # {nil, failure_result} when the home doesn't exist.
    private def resolve_ssh_key_path(name : String, facts : PluginHelpers::UserState::User?, check_mode : Bool) : {String, Nil} | {Nil, PluginResult}
      key_type = @params["ssh_key_type"]?.presence || "rsa"
      ssh_file = @params["ssh_key_file"]?.presence || ".ssh/id_#{key_type}"
      home = facts.try(&.home) || @params["home"]? || File.join("/home", name)

      return {ssh_file, nil} if ssh_file.starts_with?('/')

      unless check_mode || remote_dir_exists?(home)
        # real user.py's ssh_key_gen turns get_ssh_key_path's raise into
        # (1, '', str(e)) and main() then fails with `fail_json(name=
        # user.name, msg=err, rc=rc)` - so this failure carries the
        # account name and rc=1 like every other user.py command failure,
        # not just the message (live-verified against 2.19.11).
        return {nil, PluginResult.new(changed: false, failed: true,
          msg: "User #{name} home directory does not exist", name: name, rc: 1, key_order: USER_CMD_FAIL_ORDER)}
      end
      {File.join(home, ssh_file), nil}
    end

    private def build_keygen_command(key_type : String, key_path : String) : String
      String.build do |str|
        str << "ssh-keygen -q -t " << key_type
        if bits = @params["ssh_key_bits"]?.try(&.to_i64?)
          str << " -b " << bits if bits > 0
        end
        # Real user.py: `comment='ansible-generated on %s' %
        # socket.gethostname()` - ssh_key_comment's documented default.
        # krikri used to omit -C entirely when the param was absent, so
        # ssh-keygen's own default (user@host, e.g. root@host) landed in
        # the key instead (found live via modules_systems.yml's key
        # fingerprint byte-diff).
        str << " -C " << shell_single_quote(@params["ssh_key_comment"]?.presence || "ansible-generated on #{System.hostname}")
        str << " -f " << shell_single_quote(key_path)
        str << " -N " << shell_single_quote(@params["ssh_key_passphrase"]?.presence || "")
      end
    end

    private def apply_ssh_key(name : String, facts : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult?
      return nil unless true?(@params["generate_ssh_key"]?)

      key_type = @params["ssh_key_type"]?.presence || "rsa"
      resolved_path, path_failure = resolve_ssh_key_path(name, facts, check_mode)
      return path_failure if path_failure
      key_path = resolved_path.as(String)

      pub_path = key_path + ".pub"
      key_dir = File.dirname(key_path)

      dir_missing = !remote_dir_exists?(key_dir)
      priv_exists = remote_file_exists?(key_path)
      pub_exists = remote_file_exists?(pub_path)
      overwrite = true?(@params["force"]?)

      nothing_to_do = !dir_missing && (priv_exists || pub_exists) && !overwrite
      return nil if nothing_to_do
      return PluginResult.new(changed: true, failed: false, msg: "Would generate SSH key (check mode)") if check_mode

      if dir_missing
        uid = facts.try(&.uid)
        gid = facts.try(&.gid)
        mkdir = remote_exec("mkdir #{shell_single_quote(key_dir)} && chmod 0700 #{shell_single_quote(key_dir)}")
        return command_failure("create ssh key directory", mkdir) unless mkdir[:exit_code] == 0
        if uid && gid
          remote_exec("chown #{shell_single_quote("#{uid}:#{gid}")} #{shell_single_quote(key_dir)}")
        end
      end

      if overwrite && priv_exists
        remote_exec("rm -f #{shell_single_quote(key_path)} #{shell_single_quote(pub_path)}")
      end

      command = build_keygen_command(key_type, key_path)
      generated = remote_exec(command)
      return command_failure("generate ssh key", generated) unless generated[:exit_code] == 0

      if facts
        owner = "#{facts.uid}:#{facts.gid}"
        remote_exec("chown #{shell_single_quote(owner)} #{shell_single_quote(key_path)} #{shell_single_quote(pub_path)}")
      end

      result = PluginResult.new(changed: true, failed: false, msg: "SSH key generated")
      result.extra["ssh_key_file"] = JSON::Any.new(key_path)
      pub = remote_exec("cat #{shell_single_quote(pub_path)}")
      result.extra["ssh_public_key"] = JSON::Any.new(pub[:stdout].strip) if pub[:exit_code] == 0
      fingerprint = remote_exec("ssh-keygen -l -f #{shell_single_quote(key_path)}")
      if fingerprint[:exit_code] == 0
        result.extra["ssh_fingerprint"] = JSON::Any.new(fingerprint[:stdout].strip)
      end
      result
    end

    private def attach_user_facts(result : PluginResult, facts : PluginHelpers::UserState::User) : Nil
      result.extra["name"] = JSON::Any.new(facts.name)
      result.extra["uid"] = JSON::Any.new(facts.uid.to_i64? || 0_i64)
      result.extra["group"] = JSON::Any.new(facts.gid.to_i64? || 0_i64)
      result.extra["home"] = JSON::Any.new(facts.home)
      result.extra["shell"] = JSON::Any.new(facts.shell)
      result.extra["comment"] = JSON::Any.new(facts.comment)
    end

    # Ansible's user module echoes `name` and `state` in its result
    # on every path (its main() sets both unconditionally before any
    # branch runs). The per-account resolved facts (uid/group/home/
    # shell/comment) are attached separately by #attach_user_facts.
    private def attach_user_identity(result : PluginResult, name : String, state : String) : Nil
      result.extra["name"] = JSON::Any.new(name)
      result.extra["state"] = JSON::Any.new(state)
    end

    # password_expire_min:/_max:/_warn: - Ansible's user module sets
    # these via a separate `chage` call (neither useradd nor usermod has
    # an equivalent flag), always run after create/modify regardless of
    # whether the account was just created or already existed - dev-sec
    # os_hardening's own password-ageing tasks rely on this to actually
    # take effect (previously silently unhandled: the params were never
    # even read, so the account's real chage fields never changed no
    # matter what was requested, always reporting "already up to date").
    private def apply_password_ageing(name : String, check_mode : Bool) : PluginResult?
      min = @params["password_expire_min"]?
      max = @params["password_expire_max"]?
      warn = @params["password_expire_warn"]?
      return nil unless min || max || warn

      content = shadow_content
      return PluginResult.new(changed: false, failed: true, msg: "Could not read /etc/shadow") if content.nil?

      current = PluginHelpers::UserState.shadow_ageing(content, name)
      flags = PluginHelpers::UserState.chage_flags(current, min, max, warn)
      return PluginResult.new(changed: false, failed: false, msg: "Password ageing already up to date") if flags.empty?
      return PluginResult.new(changed: true, failed: false, msg: "Would update password ageing (check mode)") if check_mode

      result = remote_exec("chage #{flags.join(" ")} #{shell_single_quote(name)}")
      return command_failure("update password ageing", result) unless result[:exit_code] == 0
      invalidate_shadow_cache

      PluginResult.new(changed: true, failed: false, msg: "Password ageing updated")
    end

    private def create(name : String, check_mode : Bool) : PluginResult
      # Real user.py's create_user checks a given group: BEFORE useradd
      # runs and fails with a PLAIN fail_json(msg=...) - no name/rc echo
      # (live-verified: round 992000's user_fail registers [failed, msg,
      # changed, exception] with msg "Group kop_nosuchgroup does not
      # exist"). The check-mode bare-exit for a missing account already
      # happened in #ensure_present, matching Ansible's main() ordering.
      if group = @params["group"]?.presence
        unless group_exists?(group)
          return PluginResult.new(changed: false, failed: true,
            msg: "Group #{group} does not exist")
        end
      end

      local = local?
      create_home = wants_create_home?
      locked = @params["password_lock"]?.try { |v| true?(v) }
      args = PluginHelpers::UserState.useradd_args(
        name,
        @params["uid"]?,
        @params["group"]?,
        @params["groups"]?,
        @params["shell"]?,
        @params["home"]?,
        @params["comment"]?,
        true?(@params["system"]?),
        create_home,
        non_unique: true?(@params["non_unique"]?),
        skeleton: @params["skeleton"]?.presence,
        umask: @params["umask"]?.presence,
        inactive: @params["password_expire_account_disable"]?.presence,
        local: local
      ) + quote_password_flag(PluginHelpers::UserState.useradd_password_args(@params["password"]?, locked))

      # Ansible.builtin.user's own create_user_useradd (see its
      # source): when group: isn't given AND a group already exists with
      # the SAME NAME as the user being created (e.g. a role's own prior
      # `group: {name: zeppelin}` task before `user: {name: zeppelin,
      # groups: zeppelin}` - the "add this user to its own like-named
      # group via groups:/append:, not as a primary group" idiom), it
      # passes `-N` (no-user-group) to stop useradd's own DEFAULT
      # private-group-creation behavior (USERGROUPS_ENAB in /etc/
      # login.defs) from colliding with that already-existing group.
      # Without this, useradd fails outright: "group X exists - if you
      # want to add this user to that group, use -g." - found
      # benchmarking round167's buluma.zeppelin on Ubuntu 22.04.
      # libuser's luseradd spells the same flag `-n` (Ansible's own
      # local-path branch).
      if @params["group"]?.nil? && group_exists?(name)
        args.unshift(local ? "-n" : "-N")
      end

      expires = @params["expires"]?.try(&.to_i64?)
      if expires && !local
        name_arg = args.pop
        args << "-e" << "'#{PluginHelpers::UserState.expires_date(expires)}'" << name_arg
      end

      result = remote_exec("#{local ? "luseradd" : "useradd"} #{args.join(" ")}")
      return command_failure("create user", result) unless result[:exit_code] == 0
      invalidate_shadow_cache
      created = PluginResult.new(changed: true, failed: false)
      attach_raw_command_output(created, result[:stdout], result[:stderr])

      # Ansible's local-path tail (create_user_useradd's post-
      # luseradd block): expiry via a separate lchage (luseradd has no
      # -e), supplementary groups via one lgroupmod -M per group
      # (luseradd has no -G) - order per its observed behavior: lchage first.
      if local
        if expires
          days = PluginHelpers::UserState.local_expiry_days(expires)
          lchage = remote_exec("lchage -E '#{days}' #{shell_single_quote(name)}")
          return command_failure("set local account expiry", lchage) unless lchage[:exit_code] == 0
          invalidate_shadow_cache
        end

        local_group_add_commands(name).each do |cmd|
          lgroupmod = remote_exec(cmd)
          return command_failure("add local group membership", lgroupmod) unless lgroupmod[:exit_code] == 0
        end
      end

      created
    end

    private def modify(name : String, current : PluginHelpers::UserState::User, check_mode : Bool) : PluginResult
      # Real user.py's modify_user_usermod checks a given group: BEFORE
      # any flag/idempotency logic - a nonexistent group fails the task
      # even when nothing else would change (and in check mode too).
      if group = @params["group"]?.presence
        unless group_exists?(group)
          return PluginResult.new(changed: false, failed: true,
            msg: "Group #{group} does not exist")
        end
      end

      local = local?
      flags = PluginHelpers::UserState.usermod_flags(
        current,
        @params["uid"]?,
        resolve_gid(@params["group"]?),
        @params["shell"]?,
        @params["home"]?,
        @params["comment"]?,
        non_unique: true?(@params["non_unique"]?),
        move_home: true?(@params["move_home"]?),
        inactive: @params["password_expire_account_disable"]?.presence
      )

      flags += password_and_expiry_flags(name, local)
      flags += local ? [] of String : group_membership_flags(name)

      # `local: true` moves supplementary-group work out of the usermod
      # call into one lgroupmod command per group (libuser has no -G).
      local_group_cmds = local ? local_group_commands(name) : [] of String
      local_expiry_days = local ? pending_local_expiry(name) : nil

      # `usermod -d <newhome>` (already in flags above when home: changes)
      # only rewrites the passwd entry - real GNU usermod's own `-m`
      # (move the OLD home's contents to the new location) requires the
      # OLD home to actually exist, so it does nothing for an account
      # whose real prior home is elsewhere (caddy_ansible.caddy_ansible's
      # own default caddy_user: www-data, modified with `home: /home/
      # caddy` - www-data's actual home is /var/www, which exists, so
      # `-m` would move the WRONG directory's contents rather than
      # create a fresh one at the new path). Ansible's own
      # modify_user_usermod() does this as an independent, explicit step
      # (create the target dir + chown it) rather than relying on
      # usermod -m at all - found via that role's own subsequent
      # `get_url: dest: "{{ caddy_home }}/releases.txt"` failing "No such
      # file or directory" because /home/caddy was never created.
      new_home = home_needing_creation(current)

      if flags.empty? && !new_home && local_group_cmds.empty? && local_expiry_days.nil?
        return PluginResult.new(changed: false, failed: false)
      end

      return PluginResult.new(changed: true, failed: false) if check_mode

      modified : PluginResult? = nil
      unless flags.empty?
        result = remote_exec("#{local ? "lusermod" : "usermod"} #{flags.join(" ")} #{shell_single_quote(name)}")
        return command_failure("modify user", result) unless result[:exit_code] == 0
        invalidate_shadow_cache
        modified = PluginResult.new(changed: true, failed: false)
        attach_raw_command_output(modified, result[:stdout], result[:stderr])
      end

      # Ansible's modify_user_usermod local-path tail: expiry via
      # lchage (after lusermod), then one lgroupmod add/del per group.
      if days = local_expiry_days
        lchage = remote_exec("lchage -E '#{days}' #{shell_single_quote(name)}")
        return command_failure("update local account expiry", lchage) unless lchage[:exit_code] == 0
        invalidate_shadow_cache
      end

      local_group_cmds.each do |cmd|
        lgroupmod = remote_exec(cmd)
        return command_failure("update local group membership", lgroupmod) unless lgroupmod[:exit_code] == 0
      end

      if new_home
        gid = resolve_gid(@params["group"]?) || current.gid
        home_result = create_home_directory(new_home, name, gid)
        return home_result if home_result.failed?
      end

      modified || PluginResult.new(changed: true, failed: false)
    end

    # `groups:`/`append:` on an EXISTING user - found benchmarking
    # bsmeding.docker's own "Ensure docker users are added to the docker
    # group." (`groups: docker, append: true` against `root`, an
    # already-existing account). #modify's usermod_flags only ever
    # covered uid/group(primary)/shell/home/comment - groups:/append:
    # were read in #create (useradd -G) but never even looked at here,
    # so adding an existing user to a supplementary group silently did
    # nothing and always reported "already up to date" instead of
    # `usermod -G`/`-a -G`, unlike Ansible's own module.
    #
    # Current membership is read via `getent group` and each line's own
    # 4th (member-list) field - mirroring Ansible's own
    # `grp.getgrall()` + `name in g.gr_mem` check - rather than `id -Gn`,
    # which would also fold in the user's PRIMARY group (via passwd's
    # own gid field) and wrongly count that as a "current supplementary
    # group" even when the user isn't listed as an explicit member.
    private def group_membership_flags(name : String) : Array(String)
      # `groups: ""` (or an explicit null, demoted to "" on the params
      # wire) is Ansible's "clear every supplementary group"
      # spelling - user.py treats a PRESENT-but-empty groups as an empty
      # target list, so with append: false the set-difference removes
      # every current membership (live-verified: Ansible reports changed
      # and the user leaves the groups; getent group shows no members).
      # A `.presence` guard here folded "" into "param absent" and made
      # the whole modification a no-op ("User already up to date") -
      # found live via modules_systems.yml's membership-clearing probe.
      return [] of String unless @params["groups"]?
      return [] of String if local?
      groups_val = @params["groups"]?.presence

      # A full-value `groups: "{{ list_var }}"` substitution renders a
      # real multi-item list as bracketed text (`['a', 'b']`) rather
      # than a real array - naively splitting THAT on comma produces
      # malformed group names ("['a'", " 'b']"). Route through the same
      # bracket-aware normalization useradd_args's own create path uses
      # (PluginHelpers::UserState.normalize_groups_value) before
      # splitting.
      requested = groups_val ? PluginHelpers::UserState.normalize_groups_value(groups_val).split(',').map(&.strip).reject(&.empty?) : [] of String
      current_groups = current_supplementary_groups(name)
      append = true?(@params["append"]?)

      changed = append ? !(requested - current_groups).empty? : requested.sort != current_groups.sort
      return [] of String unless changed

      flag = append ? "-a -G" : "-G"
      ["#{flag} #{Shell.single_quote(requested.join(","))}"]
    end

    # `local: true`'s lgroupmod equivalent of group_membership_flags -
    # full commands, not usermod flags (libuser has no -G): one
    # `lgroupmod -M <name> <group>` per added group, plus one
    # `lgroupmod -m <name> <group>` per removed group when not appending
    # (Ansible's own modify_user_usermod local branch, adds before
    # dels). Create path only ever needs the add half.
    private def local_group_commands(name : String) : Array(String)
      # Same present-but-empty clearing semantics as
      # #group_membership_flags above.
      return [] of String unless @params["groups"]?
      groups_val = @params["groups"]?.presence

      requested = groups_val && groups_val != "[]" ? PluginHelpers::UserState.normalize_groups_value(groups_val).split(',').map(&.strip).reject(&.empty?) : [] of String
      current_groups = current_supplementary_groups(name)
      adds = (requested - current_groups).map { |group| "lgroupmod -M #{shell_single_quote(name)} #{shell_single_quote(group)}" }
      return adds if true?(@params["append"]?)

      dels = (current_groups - requested).map { |group| "lgroupmod -m #{shell_single_quote(name)} #{shell_single_quote(group)}" }
      adds + dels
    end

    # `local: true` create path: groups can't ride on luseradd (no -G),
    # so Ansible's create_user_useradd tail issues one
    # `lgroupmod -M <name> <group>` per group after it.
    private def local_group_add_commands(name : String) : Array(String)
      groups_val = @params["groups"]?.presence
      return [] of String unless groups_val && groups_val != "[]"

      requested = PluginHelpers::UserState.normalize_groups_value(groups_val).split(',').map(&.strip).reject(&.empty?)
      requested.map do |group|
        "lgroupmod -M #{shell_single_quote(name)} #{shell_single_quote(group)}"
      end
    end

    private def current_supplementary_groups(name : String) : Array(String)
      result = remote_exec("getent group")
      return [] of String unless result[:exit_code] == 0

      result[:stdout].each_line.compact_map do |line|
        fields = line.split(':')
        next nil unless fields.size >= 4
        members = fields[3].split(',').map(&.strip)
        members.includes?(name) ? fields[0] : nil
      end.to_a
    end

    # `create_home:` is Ansible's canonical param name; `createhome:`
    # (no underscore) is its documented alias - the more commonly seen
    # spelling in real playbooks (caddy_ansible.caddy_ansible's own
    # `createhome: true`). Neither this codebase's params hash nor the
    # playbook parser normalizes module-arg aliases, so a role using only
    # the alias silently fell through to the default (harmlessly, since
    # the default already matches) - checked here so an explicit
    # `createhome: false` is honored too, not just the default case.
    private def wants_create_home? : Bool
      raw = @params["create_home"]? || @params["createhome"]?
      raw.nil? || true?(raw)
    end

    private def password_and_expiry_flags(name : String, local : Bool) : Array(String)
      flags = [] of String

      password = @params["password"]?
      locked = @params["password_lock"]?.try { |v| true?(v) }
      if password || !locked.nil?
        update_password = @params["update_password"]? || "always"
        flags += quote_password_flag(
          PluginHelpers::UserState.password_update_flags(shadow_password(name), password, update_password, locked)
        )
      end

      # `local: true` never puts -e on lusermod (libuser's lusermod has
      # no expiry flag; Ansible's own local branch routes expires:
      # through a separate `lchage -E <days>` instead).
      unless local
        if expires = @params["expires"]?.try(&.to_i64?)
          if PluginHelpers::UserState.expires_changed?(expires, shadow_expire_days(name))
            flags << "-e" << "'#{PluginHelpers::UserState.expires_date(expires)}'"
          end
        end
      end

      flags
    end

    # `local: true` modify-path expiry: nil when expires: isn't given or
    # the shadow field already matches; the lchage -E day-count otherwise
    # (lusermod has no expiry flag, mirroring Ansible's own local
    # branch). lchage takes whole DAYS since epoch, not a date.
    private def pending_local_expiry(name : String) : Int64?
      expires = @params["expires"]?.try(&.to_i64?)
      return nil unless expires
      return nil unless PluginHelpers::UserState.expires_changed?(expires, shadow_expire_days(name))

      PluginHelpers::UserState.local_expiry_days(expires)
    end

    # The new home: dir modify() needs to create, or nil when create_home:
    # is off, home: isn't changing, or the target already exists.
    private def home_needing_creation(current : PluginHelpers::UserState::User) : String?
      return nil unless wants_create_home?
      new_home = @params["home"]?
      return nil unless new_home && new_home != current.home
      return nil if remote_dir_exists?(new_home)

      new_home
    end

    private def remote_dir_exists?(path : String) : Bool
      remote_exec("test -d #{shell_single_quote(path)}")[:exit_code] == 0
    end

    # Mirrors what ansible-core's user module does for a MODIFY-path
    # home directory creation (a plain mkdir + skeleton copy + chown, not
    # useradd's own -m machinery, which only applies at account-creation
    # time) - close enough for the common case (a role writing its own
    # files into a freshly-relocated home right after this task), not a
    # byte-for-byte match of every corner of CreateHomeDir/chown_homedir.
    private def create_home_directory(home : String, name : String, gid : String) : PluginResult
      q_home = shell_single_quote(home)
      q_name = shell_single_quote(name)
      mkdir = remote_exec("mkdir -p #{q_home}")
      return command_failure("create home directory", mkdir) unless mkdir[:exit_code] == 0

      # Ansible's own create_homedir: skeleton: if given, else
      # /etc/skel (modify-path home creation; useradd's own -k only
      # applies at account-creation time).
      skel = @params["skeleton"]?.presence || "/etc/skel"
      remote_exec("cp -a #{shell_single_quote(skel)}/. #{q_home}/ 2>/dev/null")

      chown = remote_exec("chown -R #{q_name}:#{shell_single_quote(gid)} #{q_home}")
      return command_failure("set home directory ownership", chown) unless chown[:exit_code] == 0

      remote_exec("chmod 0700 #{q_home}")
      PluginResult.new(changed: true, failed: false, msg: "Home directory created")
    end

    # `getent passwd`'s own primary-group field is always a raw GID
    # number, but group: is commonly given as a group *name* (the far
    # more common real-playbook usage) - comparing a name against that
    # numeric current GID string-for-string never matches, so every run
    # would emit `usermod -g <name>` again even when the account already
    # has exactly that group, making the whole modify() path silently
    # non-idempotent whenever group: is a name rather than a raw GID.
    # Found via a real playbook run over real SSH reporting changed: true
    # on every single rerun despite nothing actually changing. Resolved
    # to a GID here (via `getent group`) before comparison - already-
    # numeric input is passed through unchanged, and usermod itself
    # accepts a GID just as well as a name, so this resolved value is
    # correct for both the comparison and the eventual usermod call.
    private def group_exists?(group : String) : Bool
      remote_exec("getent group #{shell_single_quote(group)}")[:exit_code] == 0
    end

    private def resolve_gid(group : String?) : String?
      return nil unless group
      return group if group.matches?(/\A\d+\z/)

      result = remote_exec("getent group #{shell_single_quote(group)}")
      return group unless result[:exit_code] == 0

      result[:stdout].strip.split(':')[2]? || group
    end

    # /etc/shadow content, read at most once per invocation: password_-
    # and_expiry_flags, shadow_password, shadow_expire_days and
    # apply_password_ageing all used to issue their own `cat
    # /etc/shadow` round trip (up to 3 per task). Invalidated after every
    # successful account mutation so later reads see the task's own
    # changes.
    @shadow_content : String? = nil
    @shadow_loaded = false

    private def shadow_content : String?
      unless @shadow_loaded
        result = remote_exec("cat /etc/shadow")
        @shadow_content = result[:exit_code] == 0 ? result[:stdout] : nil
        @shadow_loaded = true
      end
      @shadow_content
    end

    private def invalidate_shadow_cache : Nil
      @shadow_loaded = false
      @shadow_content = nil
    end

    private def shadow_password(name : String) : String?
      content = shadow_content
      return nil if content.nil?
      PluginHelpers::UserState.shadow_password(content, name)
    end

    private def shadow_expire_days(name : String) : Int32?
      content = shadow_content
      return nil if content.nil?
      PluginHelpers::UserState.shadow_expire_days(content, name)
    end

    # The hash value following a "-p" flag is shell-quoted here (not
    # inside plugin_helpers/user_state.cr, which stays pure logic with no
    # shell-escaping concerns) since a real crypt hash (`$6$salt$hash`)
    # almost always contains `$`, which `remote_exec`'s underlying
    # `/bin/bash -c` would otherwise try to expand as a variable,
    # silently corrupting the password being set.
    private def quote_password_flag(flags : Array(String)) : Array(String)
      flags.map_with_index { |flag, i| i > 0 && flags[i - 1] == "-p" ? shell_single_quote(flag) : flag }
    end

    # Raw stdout/stderr carrier on the intermediate create/modify result -
    # #ensure_present re-attaches these (with the paired *_lines keys) to
    # the merged result via #attach_command_output.
    private def attach_raw_command_output(result : PluginResult, stdout : String, stderr : String) : Nil
      result.extra["stdout"] = JSON::Any.new(stdout) unless stdout.empty?
      result.extra["stderr"] = JSON::Any.new(stderr) unless stderr.empty?
    end

    private def command_failure(action : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      # real user.py: fail_json(name=self.name, msg=err, rc=rc) - the raw
      # stderr as msg (no "Failed to ..." prefix), plus name and rc; the
      # registered key order puts the fail_json kwargs first (name, rc,
      # live-verified vs 2.19.11: useradd UID-0 failure registers [name,
      # rc, failed, msg, changed, exception]).
      PluginResult.new(changed: false, failed: true, msg: result[:stderr],
        name: @params["name"]?, rc: result[:exit_code], key_order: USER_CMD_FAIL_ORDER)
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::UserPlugin.new(config)
plugin.run

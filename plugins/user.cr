#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/user_state"

module CrystalPlay
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
  #     a cleartext value itself, matching real Ansible's own requirement
  #     - `mkpasswd --method=sha-512`/`openssl passwd` are the usual way
  #     to produce one). Applied via `useradd -p`/`usermod -p`, matching
  #     real Ansible's own command shape exactly (verified against its
  #     actual `create_user_useradd`/`modify_user_usermod` source, not
  #     assumed) - `password_lock: true` prefixes the hash with `!`,
  #     `usermod`'s own lock-account convention.
  #   update_password (optional, default "always"): "always" reissues
  #     `-p` whenever the given hash doesn't match what's already in
  #     `/etc/shadow` for an *existing* account; "on_create" only ever
  #     applies `password:` at creation time, never touching an existing
  #     account's password - matches real Ansible's own two allowed
  #     values and default exactly. Like this codebase's own
  #     `mysql_user.cr`, this can't compare a *candidate cleartext*
  #     password to a stored hash - the caller is always expected to
  #     already have a hash, same as real Ansible itself requires, so
  #     "unchanged" means "the given hash already matches what's stored,"
  #     not "the account's password is already this."
  #   password_lock (optional, bool): locks/unlocks the account via
  #     `usermod -L`/`-U` (or folded into `-p '!hash'` instead when
  #     combined with a real password change in the same run, matching
  #     real Ansible's own mutual-exclusion between `-p` and `-L`/`-U`)
  #
  #   expires (optional): account expiration, a Unix TIMESTAMP (seconds,
  #     NOT days) - verified against real ansible/modules/user.py's own
  #     source: converted to a `YYYY-MM-DD` UTC date via `-e` on
  #     useradd/usermod; a negative value (real Ansible's own documented
  #     "-1 to remove" convention) clears the expiration (`-e ''`).
  #     Idempotency compares whole days-since-epoch against `/etc/
  #     shadow`'s own expire field (field 8), matching real Ansible's
  #     own day-level (not full-timestamp) comparison exactly - a value
  #     that maps to the same calendar day as what's already set is a
  #     no-op.
  #
  # Not implemented: any password-strength/format validation or warning
  # (real Ansible's own `check_password_encrypted` only ever warns, never
  # fails, on a value that doesn't look hashed - this plugin passes
  # `password:` straight through either way), `local` (lgroupmod/lchage
  # `--local` handling for NIS/LDAP-joined systems).
  class UserPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)
      current = lookup(name)

      if state == "absent"
        ensure_absent(name, current, check_mode)
      else
        ensure_present(name, current, check_mode)
      end
    end

    private def lookup(name : String) : PluginHelpers::UserState::User?
      result = remote_exec("getent passwd #{name}")
      return nil unless result[:exit_code] == 0
      PluginHelpers::UserState.parse(result[:stdout])
    end

    private def ensure_absent(name : String, current : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User already absent") unless current

      return PluginResult.new(changed: true, failed: false, msg: "Would remove user (check mode)") if check_mode

      args = PluginHelpers::UserState.userdel_args(name, is_true?(@params["remove"]?))
      result = remote_exec("userdel #{args.join(" ")}")
      return command_failure("remove user", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "User removed")
    end

    private def ensure_present(name : String, current : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult
      base = current ? modify(name, current, check_mode) : create(name, check_mode)
      return base if base.failed

      ageing = apply_password_ageing(name, check_mode)
      return base unless ageing
      return ageing if ageing.failed

      PluginResult.new(
        changed: base.changed || ageing.changed,
        failed: false,
        msg: ageing.changed ? ageing.msg : base.msg
      )
    end

    # password_expire_min:/_max:/_warn: - real Ansible's user module sets
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

      shadow = remote_exec("cat /etc/shadow")
      return PluginResult.new(changed: false, failed: true, msg: "Could not read /etc/shadow") unless shadow[:exit_code] == 0

      current = PluginHelpers::UserState.shadow_ageing(shadow[:stdout], name)
      flags = PluginHelpers::UserState.chage_flags(current, min, max, warn)
      return PluginResult.new(changed: false, failed: false, msg: "Password ageing already up to date") if flags.empty?
      return PluginResult.new(changed: true, failed: false, msg: "Would update password ageing (check mode)") if check_mode

      result = remote_exec("chage #{flags.join(" ")} #{name}")
      return command_failure("update password ageing", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Password ageing updated")
    end

    private def create(name : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "Would create user (check mode)") if check_mode

      create_home = @params["create_home"]?.nil? || is_true?(@params["create_home"]?)
      locked = @params["password_lock"]?.try { |v| is_true?(v) }
      args = PluginHelpers::UserState.useradd_args(
        name,
        @params["uid"]?,
        @params["group"]?,
        @params["groups"]?,
        @params["shell"]?,
        @params["home"]?,
        @params["comment"]?,
        is_true?(@params["system"]?),
        create_home
      ) + quote_password_flag(PluginHelpers::UserState.useradd_password_args(@params["password"]?, locked))

      # Real ansible.builtin.user's own create_user_useradd (see its
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
      if @params["group"]?.nil? && group_exists?(name)
        args.unshift("-N")
      end

      if expires = @params["expires"]?.try(&.to_i64?)
        name_arg = args.pop
        args << "-e" << "'#{PluginHelpers::UserState.expires_date(expires)}'" << name_arg
      end

      result = remote_exec("useradd #{args.join(" ")}")
      return command_failure("create user", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "User created")
    end

    private def modify(name : String, current : PluginHelpers::UserState::User, check_mode : Bool) : PluginResult
      flags = PluginHelpers::UserState.usermod_flags(
        current,
        @params["uid"]?,
        resolve_gid(@params["group"]?),
        @params["shell"]?,
        @params["home"]?,
        @params["comment"]?
      )

      password = @params["password"]?
      locked = @params["password_lock"]?.try { |v| is_true?(v) }
      if password || !locked.nil?
        update_password = @params["update_password"]? || "always"
        flags += quote_password_flag(
          PluginHelpers::UserState.password_update_flags(shadow_password(name), password, update_password, locked)
        )
      end

      if expires = @params["expires"]?.try(&.to_i64?)
        if PluginHelpers::UserState.expires_changed?(expires, shadow_expire_days(name))
          flags << "-e" << "'#{PluginHelpers::UserState.expires_date(expires)}'"
        end
      end

      return PluginResult.new(changed: false, failed: false, msg: "User already up to date") if flags.empty?

      return PluginResult.new(changed: true, failed: false, msg: "Would modify user (check mode)") if check_mode

      result = remote_exec("usermod #{flags.join(" ")} #{name}")
      return command_failure("modify user", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "User modified")
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
      remote_exec("getent group #{group}")[:exit_code] == 0
    end

    private def resolve_gid(group : String?) : String?
      return nil unless group
      return group if group.matches?(/\A\d+\z/)

      result = remote_exec("getent group #{group}")
      return group unless result[:exit_code] == 0

      result[:stdout].strip.split(':')[2]? || group
    end

    private def shadow_password(name : String) : String?
      result = remote_exec("cat /etc/shadow")
      return nil unless result[:exit_code] == 0
      PluginHelpers::UserState.shadow_password(result[:stdout], name)
    end

    private def shadow_expire_days(name : String) : Int32?
      result = remote_exec("cat /etc/shadow")
      return nil unless result[:exit_code] == 0
      PluginHelpers::UserState.shadow_expire_days(result[:stdout], name)
    end

    # The hash value following a "-p" flag is shell-quoted here (not
    # inside plugin_helpers/user_state.cr, which stays pure logic with no
    # shell-escaping concerns) since a real crypt hash (`$6$salt$hash`)
    # almost always contains `$`, which `remote_exec`'s underlying
    # `/bin/bash -c` would otherwise try to expand as a variable,
    # silently corrupting the password being set.
    private def quote_password_flag(flags : Array(String)) : Array(String)
      flags.map_with_index { |flag, i| i > 0 && flags[i - 1] == "-p" ? shell_quote(flag) : flag }
    end

    private def shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end

    private def command_failure(action : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Failed to #{action}: #{result[:stderr].empty? ? result[:stdout] : result[:stderr]}")
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::UserPlugin.new(config)
plugin.run

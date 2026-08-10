module CrystalPlay
  module PluginHelpers
    # UserState - pure logic for parsing `getent passwd` output and
    # deciding what (if anything) needs to change to reconcile a user
    # account with its desired state. No I/O here: the plugin itself calls
    # getent/useradd/etc and hands the results in as plain strings.
    module UserState
      record User, name : String, uid : String, gid : String, comment : String, home : String, shell : String

      # Parses a single `getent passwd <name>` line:
      # "name:password:uid:gid:comment:home:shell"
      def self.parse(line : String) : User?
        fields = line.strip.split(":")
        return nil if fields.size < 7
        User.new(fields[0], fields[2], fields[3], fields[4], fields[5], fields[6])
      end

      # useradd argument list for a brand new account. Desired values that
      # are nil are simply omitted, letting useradd apply its own defaults.
      def self.useradd_args(
        name : String,
        uid : String?,
        gid : String?,
        groups : String?,
        shell : String?,
        home : String?,
        comment : String?,
        system : Bool,
        create_home : Bool,
      ) : Array(String)
        # A blank (non-nil but empty) value - e.g. `groups: "{{
        # some_var }}"` where some_var is YAML `null`, real Ansible's
        # own format_value renders that to "" - used to add a flag with
        # no value at all ("-G " with nothing after it). Joined into one
        # shell command string with the following flags, that shifted
        # every subsequent token left by one: the *next* flag's own name
        # (e.g. "-c") got consumed as if it were THIS flag's value,
        # producing useradd's own "group '-c' does not exist" - a
        # confusing error with no evident tie back to an unrelated blank
        # groups:/uid:/etc param. Found via ansible-community.ansible-
        # vault's own `groups: "{{ vault_groups }}"` (vault_groups:
        # null in defaults/main.yml).
        args = [] of String
        args << "-u #{uid}" if uid.presence
        args << "-g #{gid}" if gid.presence
        args << "-G #{groups}" if groups.presence
        args << "-s #{shell}" if shell.presence
        args << "-d #{home}" if home.presence
        args << "-c #{comment.inspect}" if comment.presence
        args << "-r" if system
        args << (create_home ? "-m" : "-M")
        args << name
        args
      end

      # usermod flags needed to reconcile an existing account with the
      # desired attributes. Only attributes that were actually requested
      # (non-nil) and differ from the current value produce a flag.
      def self.usermod_flags(
        current : User,
        uid : String?,
        gid : String?,
        shell : String?,
        home : String?,
        comment : String?,
      ) : Array(String)
        [
          changed_flag("-u", uid, current.uid),
          changed_flag("-g", gid, current.gid),
          changed_flag("-s", shell, current.shell),
          changed_flag("-d", home, current.home),
          comment.presence && comment != current.comment ? "-c #{comment.inspect}" : nil,
        ].compact
      end

      def self.userdel_args(name : String, remove_home : Bool) : Array(String)
        remove_home ? ["-r", name] : [name]
      end

      # `/etc/shadow`'s own password-ageing fields (min/max/warn - the 4th/
      # 5th/6th colon-separated fields), for `password_expire_min:`/`_max:`/
      # `_warn:`'s idempotency check. Real Ansible's user module sets these
      # via `chage`, a separate call after useradd/usermod - neither
      # supports password-ageing flags directly (usermod's own `-m` means
      # "move home directory", not "min days"). nil for a field the account
      # has no value for at all (a freshly `useradd`'d account with no
      # `-m`/`-M`/`-W`-equivalent given), matching a missing param's own nil.
      record ShadowAgeing, min : String?, max : String?, warn : String?

      def self.shadow_ageing(shadow_content : String, name : String) : ShadowAgeing
        shadow_content.each_line do |line|
          fields = line.split(':')
          next unless fields.size >= 6 && fields[0] == name
          return ShadowAgeing.new(blank_to_nil(fields[3]), blank_to_nil(fields[4]), blank_to_nil(fields[5]))
        end
        ShadowAgeing.new(nil, nil, nil)
      end

      private def self.blank_to_nil(field : String) : String?
        field.empty? ? nil : field
      end

      # `chage -m <min> -M <max> -W <warn> <name>` flags needed to
      # reconcile the account's current password-ageing fields with the
      # desired ones - only ever emitted for a param that was actually
      # given (non-nil) and differs from the current value, same
      # changed_flag convention every other *_flags helper here uses.
      def self.chage_flags(current : ShadowAgeing, min : String?, max : String?, warn : String?) : Array(String)
        [
          changed_flag("-m", min, current.min || ""),
          changed_flag("-M", max, current.max || ""),
          changed_flag("-W", warn, current.warn || ""),
        ].compact
      end

      # Extracts the `/etc/shadow` password-hash field (the 2nd
      # colon-separated field) for *name* from a real `/etc/shadow`'s
      # full content - verified against real Ansible's own
      # `parse_shadow_file` (the fallback it uses when Python's `spwd`
      # module isn't available, which is the only shadow-reading strategy
      # this codebase replicates - no `getspnam`-equivalent libc binding
      # is needed just to read a field this codebase can already get by
      # shelling `cat /etc/shadow`, the same `remote_exec` local/remote
      # split every other plugin already uses). nil if the account has no
      # shadow entry at all (matches real Ansible's own empty-string
      # default becoming an empty comparison target).
      def self.shadow_password(shadow_content : String, name : String) : String?
        shadow_content.each_line do |line|
          fields = line.split(':')
          next unless fields.size >= 2 && fields[0] == name
          return fields[1]
        end
        nil
      end

      # Real Ansible compares password hashes with a leading `!` (its own
      # lock-marker prefix) stripped from both sides before comparing -
      # verified against its own `info[1].lstrip('!') != self.password.lstrip('!')`
      # - so locking/unlocking alone never looks like a password change.
      def self.password_matches?(current_hash : String, desired_password : String) : Bool
        current_hash.lstrip('!') == desired_password.lstrip('!')
      end

      # `useradd -p <hash>` (or `-p '!<hash>'` when password_lock: true -
      # real Ansible's own convention for "set this password, but start
      # the account locked").
      def self.useradd_password_args(password : String?, locked : Bool?) : Array(String)
        return [] of String unless password
        ["-p", locked ? "!#{password}" : password]
      end

      # usermod flags to reconcile an existing account's password/lock
      # state - verified against real Ansible's own modify_user_usermod
      # logic (including the real, easy-to-miss detail that a queued `-L`/
      # `-U` gets folded into `-p '!hash'`/`-p hash` instead, rather than
      # coexisting with it, whenever both a password update and a lock
      # state are requested together - `-p` and `-L`/`-U` are mutually
      # exclusive usermod flags).
      #
      # - `update_password: "on_create"` (real Ansible's other allowed
      #   value, vs. the default `"always"`) means an existing account's
      #   password is never touched here at all, only at creation time -
      #   this codebase's own mysql_user.cr already documents the same
      #   simplification for MySQL: unlike real Ansible, this can't
      #   compare a *candidate cleartext* password to a stored hash (the
      #   caller is always expected to pass an already-hashed value, same
      #   as real Ansible itself requires), so "unchanged" here means
      #   "the given hash already matches what's stored," not "the
      #   account's password is already this."
      def self.password_update_flags(current_hash : String?, desired_password : String?, update_password : String, locked : Bool?) : Array(String)
        if desired_password && update_password == "always" && !password_matches?(current_hash || "", desired_password)
          return ["-p", locked ? "!#{desired_password}" : desired_password]
        end

        lock_flag(current_hash, locked)
      end

      # -L/-U only ever apply on their own when #password_update_flags
      # above didn't already fold the lock state into a -p change.
      private def self.lock_flag(current_hash : String?, locked : Bool?) : Array(String)
        currently_locked = (current_hash || "").starts_with?('!')

        if locked == true && !currently_locked
          ["-L"]
        elsif locked == false && currently_locked
          ["-U"]
        else
          [] of String
        end
      end

      private def self.changed_flag(flag : String, desired : String?, current : String) : String?
        desired.presence && desired != current ? "#{flag} #{desired}" : nil
      end
    end
  end
end

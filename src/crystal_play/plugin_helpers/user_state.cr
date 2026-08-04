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
        args = [] of String
        args << "-u #{uid}" if uid
        args << "-g #{gid}" if gid
        args << "-G #{groups}" if groups
        args << "-s #{shell}" if shell
        args << "-d #{home}" if home
        args << "-c #{comment.inspect}" if comment
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
          comment && comment != current.comment ? "-c #{comment.inspect}" : nil,
        ].compact
      end

      def self.userdel_args(name : String, remove_home : Bool) : Array(String)
        remove_home ? ["-r", name] : [name]
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
        desired && desired != current ? "#{flag} #{desired}" : nil
      end
    end
  end
end

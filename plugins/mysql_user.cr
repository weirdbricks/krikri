#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/mysql_connection"
require "../src/crystal_play/plugin_helpers/mysql_privileges"

module CrystalPlay
  # MySQL user plugin - creates/removes a user and manages its
  # privileges. Compatible with Ansible's community.mysql.mysql_user
  # module.
  #
  # See plugins/mysql_db.cr's module comment for the shared architecture
  # note (talks to the server directly over MySQL's own wire protocol via
  # a fork of crystal-lang/crystal-mysql).
  #
  # Supported parameters:
  # - name: username (required)
  # - password: only applied when creating a new user, or when an
  #   existing user's password is updated (update_password: always,
  #   the default - see below)
  # - host: the 'host' part of user@host (default "localhost", matching
  #   real Ansible's own default - not "%")
  # - state: present (default) / absent
  # - priv: "db.table:PRIV1,PRIV2" (multiple grants separated by "/"),
  #   same format real Ansible's mysql_user uses - see
  #   src/crystal_play/plugin_helpers/mysql_privileges.cr. Diffed against
  #   the account's actual SHOW GRANTS output; a mismatch REVOKEs
  #   everything and re-GRANTs the desired set from scratch rather than
  #   computing a minimal add/remove delta - simpler, and idempotent
  #   either way, just not the smallest possible set of statements.
  # - update_password: "always" (default, matching real Ansible) or
  #   "on_create". "always" compares the account's current password hash
  #   (mysql.user.authentication_string) against what the given password
  #   would hash to via `SELECT PASSWORD(...)` before deciding whether an
  #   ALTER is even needed - matching real Ansible's own idempotent
  #   behavior for mysql_native_password/MariaDB accounts (round 18; was
  #   previously an unconditional ALTER + changed: true on every run).
  #   Falls back to the previous always-alter behavior if that comparison
  #   itself fails for any reason (e.g. a caching_sha2_password account on
  #   real MySQL 8, where PASSWORD() doesn't apply the same way).
  # - plugin/plugin_hash_string/plugin_auth_string: non-password
  #   authentication, matching real Ansible's own mysql_user module
  #   (verified against community.mysql's module_utils/user.py). Auth
  #   clause precedence (highest first): password, then
  #   plugin+plugin_hash_string (`IDENTIFIED WITH <p> AS <hash>`), then
  #   plugin+plugin_auth_string (`IDENTIFIED WITH <p> BY <auth>`, with
  #   MariaDB's pam->USING and ed25519->USING PASSWORD() special cases),
  #   then bare plugin (`IDENTIFIED WITH <p>`). weaponized for creating
  #   unix_socket/auth_socket accounts (the common MariaDB/Debian root
  #   pattern): `plugin: unix_socket` -> `CREATE USER ... IDENTIFIED WITH
  #   unix_socket`. The update path diffs current plugin+authentication_
  #   string against the desired and only ALTERs on a real change.
  # - login_host/login_port/login_user/login_password/login_unix_socket
  # - check_mode
  # - host_all: operate on every existing host row for name: instead of
  #   a single host: - see #ensure_present_all_hosts/#ensure_absent_
  #   all_hosts. priv: is not applied in this mode (dev-sec mysql_
  #   hardening's own two host_all: callers - root's password and
  #   removing anonymous users - never combine it with priv: either).
  #
  # Not implemented: update_password: on_new_username, salt:, append_privs:/
  # subtract_privs: (this always does a full revoke-then-regrant instead),
  # resource_limits:, locked:, config_file:.
  class MysqlUserPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      host = @params["host"]? || "localhost"
      state = @params["state"]? || "present"
      password = @params["password"]?
      priv = @params["priv"]?
      update_password = @params["update_password"]? || "always"
      check_mode = is_true?(@params["check_mode"]?)
      host_all = is_true?(@params["host_all"]?)

      plugin = @params["plugin"]?
      plugin_hash_string = @params["plugin_hash_string"]?
      plugin_auth_string = @params["plugin_auth_string"]?

      unless ["always", "on_create"].includes?(update_password)
        return PluginResult.new(changed: false, failed: true, msg: "update_password must be 'always' or 'on_create', got '#{update_password}'")
      end

      if password && plugin
        return PluginResult.new(changed: false, failed: true, msg: "password and plugin are mutually exclusive")
      end

      if plugin_hash_string && plugin_auth_string
        return PluginResult.new(changed: false, failed: true, msg: "plugin_hash_string and plugin_auth_string are mutually exclusive")
      end

      if (plugin_hash_string || plugin_auth_string) && !plugin
        return PluginResult.new(changed: false, failed: true, msg: "plugin is required when plugin_hash_string or plugin_auth_string is given")
      end

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
      )

      DB.open(uri) do |connection|
        if host_all
          existing_hosts = user_hosts(connection, name)
          if state == "absent"
            ensure_absent_all_hosts(connection, name, existing_hosts, check_mode)
          else
            ensure_present_all_hosts(connection, name, existing_hosts, host, password, update_password,
              plugin, plugin_hash_string, plugin_auth_string, check_mode)
          end
        else
          exists = user_exists?(connection, name, host)

          if state == "absent"
            ensure_absent(connection, name, host, exists, check_mode)
          else
            ensure_present(connection, name, host, exists, password, update_password, priv,
              plugin, plugin_hash_string, plugin_auth_string, check_mode)
          end
        end
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the MySQL server: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginResult.new(changed: false, failed: true, msg: "MySQL error: #{ex.message}")
    end

    private def ensure_present(
      db : DB::Database, name : String, host : String, exists : Bool,
      password : String?, update_password : String, priv : String?,
      plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?, check_mode : Bool,
    ) : PluginResult
      early, changed = create_or_update_account(db, name, host, exists, password, update_password,
        plugin, plugin_hash_string, plugin_auth_string, check_mode)
      return early if early

      early, changed = apply_priv_if_needed(db, name, host, exists, changed, priv, check_mode)
      return early if early

      PluginResult.new(changed: changed, failed: false, msg: changed ? "Updated user #{name}@#{host}" : "User #{name}@#{host} already up to date")
    end

    # Creates the account if it doesn't exist yet, or updates its
    # password if it does (and update_password: is "always"). Returns
    # {early_result, changed} - early_result is non-nil only for a
    # check-mode short-circuit, which the caller returns immediately.
    private def create_or_update_account(
      db : DB::Database, name : String, host : String, exists : Bool,
      password : String?, update_password : String,
      plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?, check_mode : Bool,
    ) : {PluginResult?, Bool}
      unless exists
        return {PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host} would be created"), false} if check_mode

        clause = build_auth_clause(password, plugin, plugin_hash_string, plugin_auth_string)
        db.exec "CREATE USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        return {nil, true}
      end

      return {nil, false} unless update_password == "always"
      return {nil, false} unless password || plugin

      if password
        return plugin_or_password_update(db, name, host, password, update_password, check_mode)
      else
        # Non-password auth: diff the account's current plugin (and, when a
        # hash/auth string was given, its authentication_string) against the
        # desired value, ALTERing only on a real change - matching real
        # Ansible's own plugin idempotency. Bare `plugin: unix_socket`/`auth_socket`
        # (the auth_socket account pattern) compares the plugin column only.
        return {nil, false} if plugin_matches?(db, name, host, plugin.not_nil!, plugin_hash_string, plugin_auth_string)

        return {PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host}'s authentication would be updated"), false} if check_mode

        clause = build_auth_clause(nil, plugin, plugin_hash_string, plugin_auth_string)
        db.exec "ALTER USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        {nil, true}
      end
    end

    private def plugin_or_password_update(
      db : DB::Database, name : String, host : String, password : String,
      update_password : String, check_mode : Bool,
    ) : {PluginResult?, Bool}
      # Real bug found benchmarking robertdebock.mysql's own "Create
      # users" task (round 18): update_password: always (the default,
      # matching real Ansible - the role leaves it unset) previously
      # reissued ALTER USER ... IDENTIFIED BY unconditionally on every
      # run, reporting changed: true even when the password was already
      # exactly what was requested - a genuine idempotency divergence
      # from real ansible-playbook, which compares the account's current
      # password hash (mysql.user.authentication_string, the
      # mysql_native_password/MariaDB format) against what the given
      # password WOULD hash to (`SELECT PASSWORD(...)`) before deciding
      # whether an ALTER is even needed. Falls back to the previous
      # always-alter behavior if the hash comparison itself fails for any
      # reason (e.g. a caching_sha2_password account on real MySQL 8,
      # where PASSWORD() doesn't apply the same way) - safe either way,
      # just not idempotent in that narrower case, same as before.
      if password_already_matches?(db, name, host, password)
        return {nil, false}
      end

      return {PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host}'s password would be updated"), false} if check_mode

      db.exec "ALTER USER #{quote_str(name)}@#{quote_str(host)} IDENTIFIED BY #{quote_str(password)}"
      {nil, true}
    end

    # Builds the CREATE/ALTER USER auth clause, matching real Ansible's
    # mysql_user module precedence (community.mysql module_utils/user.py):
    # password first, then plugin+hash (`IDENTIFIED WITH p AS hash`), then
    # plugin+auth_string (`IDENTIFIED WITH p BY auth`, with MariaDB pam ->
    # USING and ed25519 -> USING PASSWORD() special cases), then bare
    # plugin (`IDENTIFIED WITH p`).
    private def build_auth_clause(
      password : String?, plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?,
    ) : String
      if password
        " IDENTIFIED BY #{quote_str(password)}"
      elsif plugin && plugin_hash_string
        " IDENTIFIED WITH #{plugin} AS #{quote_str(plugin_hash_string)}"
      elsif plugin && plugin_auth_string
        if plugin == "pam"
          " IDENTIFIED WITH #{plugin} USING #{quote_str(plugin_auth_string)}"
        elsif plugin == "ed25519"
          " IDENTIFIED WITH #{plugin} USING PASSWORD(#{quote_str(plugin_auth_string)})"
        else
          " IDENTIFIED WITH #{plugin} BY #{quote_str(plugin_auth_string)}"
        end
      elsif plugin
        " IDENTIFIED WITH #{plugin}"
      else
        ""
      end
    end

    # True when the account's current plugin (and authentication_string,
    # when a hash/auth string was desired) already matches what was asked,
    # so no ALTER is needed.
    private def plugin_matches?(
      db : DB::Database, name : String, host : String, plugin : String,
      plugin_hash_string : String?, plugin_auth_string : String?,
    ) : Bool
      # Does the comparison entirely server-side (a boolean 0/1), rather
      # than pulling the raw column back through the driver as a value -
      # mysql.user's plugin/authentication_string columns are types this
      # vendored driver has no `read` for (the same "not supported read"
      # limitation password_already_matches? documents for the LONGTEXT
      # authentication_string). An integer result is a type every driver
      # here already reads fine.
      matches = db.query_all(
        "SELECT plugin = ? FROM mysql.user WHERE User = ? AND Host = ?",
        plugin, name, host, as: Int32
      ).first?
      return false unless matches == 1

      # Bare plugin (auth_socket/unix_socket pattern): a matching plugin
      # column is sufficient - no auth string to verify.
      return true unless plugin_hash_string || plugin_auth_string

      # With a hash/auth string, verify the account's authentication_string
      # matches server-side as well.
      want = plugin_hash_string || plugin_auth_string
      auth_matches = db.query_all(
        "SELECT authentication_string = ? FROM mysql.user WHERE User = ? AND Host = ?",
        want, name, host, as: Int32
      ).first?
      auth_matches == 1
    rescue
      false
    end

    private def password_already_matches?(db : DB::Database, name : String, host : String, password : String) : Bool
      # Does the comparison entirely server-side (`authentication_string =
      # PASSWORD(...)`, a boolean 0/1) rather than pulling
      # mysql.user.authentication_string back through the driver as a
      # value - that column is LONGTEXT on the wire, a MySQL protocol
      # type this vendored driver's type table has no `read` for at all
      # (`MySql::Type::LongBlob` has no override, only the base `raise
      # "not supported read"`), so fetching it directly always raised and
      # fell into the "assume it needs updating" rescue below, defeating
      # the whole point of this check. An integer result is a type every
      # driver here already reads fine (ordinary registered-result/fact
      # queries do this constantly).
      matches = db.query_all(
        "SELECT authentication_string = PASSWORD(?) FROM mysql.user WHERE User = ? AND Host = ?",
        password, name, host, as: Int32
      ).first?
      matches == 1
    rescue
      false
    end

    # Applies priv: (if given) when it differs from the account's
    # current grants. Returns {early_result, changed} the same way
    # #create_or_update_account does - changed carries forward the
    # value the caller already had if nothing here needed to change.
    private def apply_priv_if_needed(
      db : DB::Database, name : String, host : String, exists : Bool, changed : Bool, priv : String?, check_mode : Bool,
    ) : {PluginResult?, Bool}
      return {nil, changed} unless priv

      desired = PluginHelpers::MysqlPrivileges.desired_grants(priv)
      current = exists && !changed ? current_grants(db, name, host) : Hash(String, Set(String)).new
      return {nil, changed} if current == desired

      return {PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host}'s privileges would be updated"), changed} if check_mode

      apply_grants(db, name, host, desired)
      {nil, true}
    end

    private def ensure_absent(db : DB::Database, name : String, host : String, exists : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User already absent") unless exists
      return PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host} would be removed") if check_mode

      db.exec "DROP USER #{quote_str(name)}@#{quote_str(host)}"
      PluginResult.new(changed: true, failed: false, msg: "Removed user #{name}@#{host}")
    end

    private def user_exists?(db : DB::Database, name : String, host : String) : Bool
      db.query_all("SELECT User FROM mysql.user WHERE User = ? AND Host = ?", name, host, as: String).size > 0
    end

    private def user_hosts(db : DB::Database, name : String) : Array(String)
      db.query_all("SELECT Host FROM mysql.user WHERE User = ?", name, as: String)
    end

    # `host_all: true` (dev-sec mysql_hardening's own "Ensure that the
    # root password is present" / "Ensure that anonymous users are
    # absent" tasks) operates on every existing host row for *name*
    # instead of a single `host:`. Real Ansible's own module: for
    # `present`, updates every existing account's password if any exist;
    # if none exist yet, falls back to creating exactly one account at
    # `host:` (default "localhost") - `host_all` alone never invents
    # more than one new account out of nothing.
    private def ensure_present_all_hosts(
      db : DB::Database, name : String, existing_hosts : Array(String), fallback_host : String,
      password : String?, update_password : String,
      plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?, check_mode : Bool,
    ) : PluginResult
      if existing_hosts.empty?
        return ensure_present(db, name, fallback_host, false, password, update_password, nil,
          plugin, plugin_hash_string, plugin_auth_string, check_mode)
      end

      changed = false
      existing_hosts.each do |host|
        next unless update_password == "always" && (password || plugin)
        return PluginResult.new(changed: true, failed: false, msg: "User #{name}'s #{password ? "password" : "authentication"} would be updated on all hosts") if check_mode

        clause = build_auth_clause(password, plugin, plugin_hash_string, plugin_auth_string)
        db.exec "ALTER USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        changed = true
      end

      PluginResult.new(changed: changed, failed: false, msg: changed ? "Updated user #{name} on all hosts" : "User #{name} already up to date on all hosts")
    end

    private def ensure_absent_all_hosts(db : DB::Database, name : String, existing_hosts : Array(String), check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User already absent") if existing_hosts.empty?
      return PluginResult.new(changed: true, failed: false, msg: "User #{name} would be removed from all hosts") if check_mode

      existing_hosts.each { |host| db.exec "DROP USER #{quote_str(name)}@#{quote_str(host)}" }
      PluginResult.new(changed: true, failed: false, msg: "Removed user #{name} from #{existing_hosts.size} host(s)")
    end

    private def current_grants(db : DB::Database, name : String, host : String) : Hash(String, Set(String))
      rows = db.query_all("SHOW GRANTS FOR #{quote_str(name)}@#{quote_str(host)}", as: String)
      PluginHelpers::MysqlPrivileges.current_grants(rows)
    end

    private def apply_grants(db : DB::Database, name : String, host : String, desired : Hash(String, Set(String)))
      account = "#{quote_str(name)}@#{quote_str(host)}"

      db.exec "REVOKE ALL PRIVILEGES, GRANT OPTION FROM #{account}"

      desired.each do |target, privileges|
        grant_option = privileges.includes?("GRANT")
        list = privileges.reject { |priv_name| priv_name == "GRANT" }
        list = ["USAGE"] if list.empty?

        clause = grant_option ? " WITH GRANT OPTION" : ""
        db.exec "GRANT #{list.join(", ")} ON #{quote_target(target)} TO #{account}#{clause}"
      end
    end

    private def quote_str(s : String) : String
      "'" + s.gsub("'", "''") + "'"
    end

    private def quote_ident(s : String) : String
      "`" + s.gsub("`", "``") + "`"
    end

    # "db.table" -> "`db`.`table`"; "*" components (db.* / *.*) are left
    # bare since MySQL's GRANT syntax doesn't accept a quoted wildcard.
    private def quote_target(target : String) : String
      db_part, _, table_part = target.partition('.')
      quoted_db = db_part == "*" ? "*" : quote_ident(db_part)
      quoted_table = table_part == "*" ? "*" : quote_ident(table_part)
      "#{quoted_db}.#{quoted_table}"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::MysqlUserPlugin.new(config)
plugin.run

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
  #   "on_create". "always" is NOT truly idempotent here: unlike real
  #   Ansible (which can compare password hashes for
  #   mysql_native_password accounts specifically), this always reissues
  #   ALTER USER ... IDENTIFIED BY and reports changed: true whenever a
  #   password: is given for an existing user - a documented
  #   simplification, not an oversight. Use update_password: on_create to
  #   avoid this if password drift-detection isn't needed.
  # - login_host/login_port/login_user/login_password/login_unix_socket
  # - check_mode
  #
  # Not implemented: update_password: on_new_username, plugin:/
  # plugin_hash_string:/plugin_auth_string: (non-password auth methods),
  # append_privs:/subtract_privs: (this always does a full
  # revoke-then-regrant instead), host_all:, resource_limits:, locked:,
  # config_file:.
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

      unless ["always", "on_create"].includes?(update_password)
        return PluginResult.new(changed: false, failed: true, msg: "update_password must be 'always' or 'on_create', got '#{update_password}'")
      end

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
      )

      DB.open(uri) do |db|
        exists = user_exists?(db, name, host)

        if state == "absent"
          ensure_absent(db, name, host, exists, check_mode)
        else
          ensure_present(db, name, host, exists, password, update_password, priv, check_mode)
        end
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the MySQL server: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginResult.new(changed: false, failed: true, msg: "MySQL error: #{ex.message}")
    end

    private def ensure_present(
      db : DB::Database, name : String, host : String, exists : Bool,
      password : String?, update_password : String, priv : String?, check_mode : Bool,
    ) : PluginResult
      changed = false

      unless exists
        return PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host} would be created") if check_mode

        clause = password ? " IDENTIFIED BY #{quote_str(password)}" : ""
        db.exec "CREATE USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        changed = true
      else
        if update_password == "always" && password
          return PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host}'s password would be updated") if check_mode

          db.exec "ALTER USER #{quote_str(name)}@#{quote_str(host)} IDENTIFIED BY #{quote_str(password)}"
          changed = true
        end
      end

      if priv
        desired = PluginHelpers::MysqlPrivileges.desired_grants(priv)
        current = exists && !changed ? current_grants(db, name, host) : Hash(String, Set(String)).new

        if current != desired
          return PluginResult.new(changed: true, failed: false, msg: "User #{name}@#{host}'s privileges would be updated") if check_mode

          apply_grants(db, name, host, desired)
          changed = true
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: changed ? "Updated user #{name}@#{host}" : "User #{name}@#{host} already up to date")
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

    private def current_grants(db : DB::Database, name : String, host : String) : Hash(String, Set(String))
      rows = db.query_all("SHOW GRANTS FOR #{quote_str(name)}@#{quote_str(host)}", as: String)
      PluginHelpers::MysqlPrivileges.current_grants(rows)
    end

    private def apply_grants(db : DB::Database, name : String, host : String, desired : Hash(String, Set(String)))
      account = "#{quote_str(name)}@#{quote_str(host)}"

      db.exec "REVOKE ALL PRIVILEGES, GRANT OPTION FROM #{account}"

      desired.each do |target, privileges|
        grant_option = privileges.includes?("GRANT")
        list = privileges.reject { |p| p == "GRANT" }
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

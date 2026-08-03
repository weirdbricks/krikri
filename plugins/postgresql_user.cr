#!/usr/bin/env crystal

require "json"
require "pg"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/postgresql_connection"
require "../src/crystal_play/plugin_helpers/postgresql_role_flags"

module CrystalPlay
  # PostgreSQL user (role) plugin - creates/removes a role and manages
  # its attribute flags. Compatible with Ansible's
  # community.postgresql.postgresql_user module.
  #
  # See plugins/postgresql_db.cr's module comment for the shared
  # architecture note (talks to the server directly over PostgreSQL's own
  # wire protocol via will/crystal-pg).
  #
  # Real Ansible splits role management (this module) from database/table
  # privilege GRANTs (a separate module, postgresql_privs) - this plugin
  # follows the same split rather than folding privilege management into
  # user management the way this codebase's mysql_user.cr does (MySQL's
  # own GRANT model ties privileges directly to the user account;
  # PostgreSQL's doesn't).
  #
  # Supported parameters:
  # - name: role name (required)
  # - password: applied whenever given, for both newly-created and
  #   already-existing roles - unlike real Ansible (which can compare a
  #   candidate password against the role's stored SCRAM/MD5 verifier to
  #   stay idempotent), this always reissues ALTER ROLE ... PASSWORD and
  #   reports changed: true whenever a password: is given for an existing
  #   role. A documented simplification, not an oversight - matching this
  #   codebase's mysql_user.cr's own update_password: always behavior.
  # - state: present (default) / absent
  # - role_attr_flags: "LOGIN,CREATEDB,NOSUPERUSER" (comma-separated,
  #   real Ansible's own format) - via a new pure
  #   src/crystal_play/plugin_helpers/postgresql_role_flags.cr, diffed
  #   against the role's actual pg_roles attribute columns; only the
  #   flags actually given are compared, so omitting role_attr_flags:
  #   entirely never triggers a change on its account.
  # - login_host (default "localhost"), login_port (default 5432),
  #   login_user (default "postgres"), login_password,
  #   login_unix_socket (takes precedence over login_host/login_port),
  #   login_db (database to connect to - default "postgres", matching
  #   real Ansible's own default)
  # - check_mode
  #
  # Not implemented: database/table privilege grants (see above -
  # that's postgresql_privs's job, not implemented in this codebase
  # either), expires:, conn_limit:, comment:, session_role:,
  # fail_on_user:, trust_input:.
  class PostgresqlUserPlugin < BasePlugin
    ROLE_ATTR_COLUMNS = %w[rolsuper rolinherit rolcreaterole rolcreatedb rolcanlogin rolreplication rolbypassrls]

    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      password = @params["password"]?
      check_mode = is_true?(@params["check_mode"]?)

      desired_flags = @params["role_attr_flags"]?.try { |spec| PluginHelpers::PostgresqlRoleFlags.parse(spec) }

      uri = PluginHelpers::PostgresqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]? || "postgres",
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        dbname: @params["login_db"]? || "postgres",
      )

      DB.open(uri) do |db|
        existing_flags = current_flags(db, name)

        if state == "absent"
          ensure_absent(db, name, !!existing_flags, check_mode)
        else
          ensure_present(db, name, existing_flags, password, desired_flags, check_mode)
        end
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the PostgreSQL server: #{ex.message}")
    rescue ex : PQ::PQError
      PluginResult.new(changed: false, failed: true, msg: "PostgreSQL error: #{ex.message}")
    end

    private def ensure_present(
      db : DB::Database, name : String, existing_flags : Hash(String, Bool)?,
      password : String?, desired_flags : Hash(String, Bool)?, check_mode : Bool,
    ) : PluginResult
      changed = false

      unless existing_flags
        return PluginResult.new(changed: true, failed: false, msg: "Role #{name} would be created") if check_mode

        clause = String.build do |s|
          s << " " << PluginHelpers::PostgresqlRoleFlags.to_sql(desired_flags) if desired_flags
          s << " PASSWORD " << quote_str(password) if password
        end
        db.exec "CREATE ROLE #{quote_ident(name)}#{clause}"
        changed = true
      else
        if password
          return PluginResult.new(changed: true, failed: false, msg: "Role #{name}'s password would be updated") if check_mode

          db.exec "ALTER ROLE #{quote_ident(name)} PASSWORD #{quote_str(password)}"
          changed = true
        end

        if desired_flags && flags_differ?(existing_flags, desired_flags)
          return PluginResult.new(changed: true, failed: false, msg: "Role #{name}'s attributes would be updated") if check_mode

          db.exec "ALTER ROLE #{quote_ident(name)} #{PluginHelpers::PostgresqlRoleFlags.to_sql(desired_flags)}"
          changed = true
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: changed ? "Updated role #{name}" : "Role #{name} already up to date")
    end

    private def ensure_absent(db : DB::Database, name : String, exists : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Role already absent") unless exists
      return PluginResult.new(changed: true, failed: false, msg: "Role #{name} would be removed") if check_mode

      db.exec "DROP ROLE #{quote_ident(name)}"
      PluginResult.new(changed: true, failed: false, msg: "Removed role #{name}")
    end

    private def flags_differ?(existing : Hash(String, Bool), desired : Hash(String, Bool)) : Bool
      desired.any? { |flag, value| existing[flag]? != value }
    end

    # Returns the role's current attributes (only the flags this plugin
    # knows about - see PostgresqlRoleFlags::FLAGS) as {flag => bool}, or
    # nil if the role doesn't exist.
    private def current_flags(db : DB::Database, name : String) : Hash(String, Bool)?
      columns = ROLE_ATTR_COLUMNS.join(", ")
      row = db.query_one? "SELECT #{columns} FROM pg_roles WHERE rolname = $1", name, as: {Bool, Bool, Bool, Bool, Bool, Bool, Bool}
      return nil unless row

      {
        "SUPERUSER"   => row[0],
        "INHERIT"     => row[1],
        "CREATEROLE"  => row[2],
        "CREATEDB"    => row[3],
        "LOGIN"       => row[4],
        "REPLICATION" => row[5],
        "BYPASSRLS"   => row[6],
      }
    end

    private def quote_ident(s : String) : String
      "\"" + s.gsub("\"", "\"\"") + "\""
    end

    private def quote_str(s : String) : String
      "'" + s.gsub("'", "''") + "'"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::PostgresqlUserPlugin.new(config)
plugin.run

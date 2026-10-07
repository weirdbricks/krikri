#!/usr/bin/env crystal

require "json"
require "pg"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/postgresql_connection"
require "../src/krikri/plugin_helpers/postgresql_deprecations"
require "../src/krikri/plugin_helpers/postgresql_password_verifier"
require "../src/krikri/plugin_helpers/postgresql_role_flags"
require "../src/krikri/plugin_helpers/sql_quoting"

module Krikri
  # PostgreSQL user (role) plugin - creates/removes a role and manages
  # its attribute flags. Compatible with Ansible's
  # community.postgresql.postgresql_user module.
  #
  # See plugins/postgresql_db.cr's module comment for the shared
  # architecture note (talks to the server directly over PostgreSQL's own
  # wire protocol via will/crystal-pg).
  #
  # Ansible splits role management (this module) from database/table
  # privilege GRANTs (a separate module, postgresql_privs) - this plugin
  # follows the same split rather than folding privilege management into
  # user management the way this codebase's mysql_user.cr does (MySQL's
  # own GRANT model ties privileges directly to the user account;
  # PostgreSQL's doesn't).
  #
  # Supported parameters:
  # - name: role name (required)
  # - password: idempotent, like Ansible - the desired password is
  #   diffed against the role's stored pg_authid.rolpassword verifier
  #   (see PostgresqlPasswordVerifier: SCRAM verifiers compared by
  #   recomputing the ServerKey from the plaintext, pre-hashed inputs
  #   compared verbatim, plaintext vs. an md5-default server via
  #   PostgreSQL's own 'md5' + md5(password + username) form), and the
  #   ALTER ROLE ... PASSWORD only runs when they actually differ.
  # - state: present (default) / absent
  # - role_attr_flags: "LOGIN,CREATEDB,NOSUPERUSER" (comma-separated,
  #   Ansible's own format) - via a new pure
  #   src/krikri/plugin_helpers/postgresql_role_flags.cr, diffed
  #   against the role's actual pg_roles attribute columns; only the
  #   flags actually given are compared, so omitting role_attr_flags:
  #   entirely never triggers a change on its account.
  # - login_host (default "localhost"), login_port (default 5432),
  #   login_user (default "postgres"), login_password,
  #   login_unix_socket (takes precedence over login_host/login_port),
  #   login_db (database to connect to - default "postgres", matching
  #   Ansible's own default)
  # - check_mode
  #
  # Not implemented: database/table privilege grants (see above -
  # that's postgresql_privs's job, not implemented in this codebase
  # either), expires:, conn_limit:, comment:, session_role:,
  # fail_on_user:, trust_input:.
  class PostgresqlUserPlugin < BasePlugin
    ROLE_ATTR_COLUMNS = %w[rolsuper rolinherit rolcreaterole rolcreatedb rolcanlogin rolreplication rolbypassrls]

    # community.postgresql's shared connection spec still ACCEPTS its
    # deprecated aliases, and Ansible warns about each one the task uses
    # (both on stderr and in the registered result's trailing
    # `deprecations` list) - see PluginHelpers::PostgresqlDeprecations.
    def finalize_result(result : PluginResult) : PluginResult
      PluginHelpers::PostgresqlDeprecations.finalize(result, @params, db_alias: true)
    end

    def execute : PluginResult
      # Ansible's `name:` param has `aliases: ['user']` - same bug
      # class as postgresql_db's `db:` alias (round 43,
      # robertdebock.postgres): its own "Create postgres users" task
      # writes `user: "{{ item.name }}"`, which this plugin didn't
      # recognize at all.
      name = @params["name"]? || @params["user"]?
      unless name
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: user")
      end

      state = @params["state"]? || "present"
      password = @params["password"]?
      check_mode = true?(@params["_ansible_check_mode"]?)

      desired_flags = @params["role_attr_flags"]?.try { |spec| PluginHelpers::PostgresqlRoleFlags.parse(spec) }

      # Ansible's `login_db:` param has a deprecated `aliases:
      # [db]` - same bug class as this file's own `user:`/`name:` fix
      # above. robertdebock.postgres's own "Create postgres users" task
      # writes `db: "{{ item.db | default(omit) }}"` (the alias), which
      # this plugin didn't recognize, always connecting to the
      # "postgres" default database instead of the one the role
      # actually wanted the user granted on.
      login = PluginHelpers::PostgresqlConnection.resolve_login_params(@params)
      uri = PluginHelpers::PostgresqlConnection.build_uri(
        host: login[:host],
        port: login[:port],
        user: login[:user] || "postgres",
        password: login[:password],
        unix_socket: login[:unix_socket],
        dbname: @params["login_db"]? || @params["db"]? || "postgres",
      )

      PluginHelpers::PostgresqlConnection.open(uri, @params) do |dbcon|
        existing_flags = current_flags(dbcon, name)

        if state == "absent"
          ensure_absent(dbcon, name, !!existing_flags, check_mode)
        else
          ensure_present(dbcon, name, existing_flags, password, desired_flags, check_mode)
        end
      end
    rescue ex : DB::ConnectionRefused
      PluginHelpers::DbErrors.pg_connection_failed(ex, @params)
    rescue ex : PQ::PQError
      PluginHelpers::DbErrors.query_failed(ex, "PostgreSQL")
    end

    # Ansible's exit_json(**kw) with kw = dict(user=user) then
    # kw['user_removed'], kw['changed'], kw['queries']
    # (postgresql_user.py:919, 955/965, 975-976) - `failed: false` is
    # backfilled by the controller after the module's own kwargs. `queries`
    # is the list of SQL statement TEMPLATES the module appended to
    # executed_queries (unmogrified - the %(password)s placeholders stay
    # literal, and the flags string is appended verbatim after a join, so a
    # no-flag CREATE USER carries Ansible's trailing space). Live-verified
    # against ansible-core 2.19.11 + community.postgresql 4.2.0.
    SUCCESS_KEY_ORDER = %w[user user_removed changed queries failed]

    private def user_result(
      name : String, changed : Bool, queries : Array(String), user_removed : Bool? = nil,
    ) : PluginResult
      result = PluginResult.new(changed: changed, failed: false, user: name, queries: queries,
        failed_flag: true, key_order: SUCCESS_KEY_ORDER)
      result.extra["user_removed"] = JSON::Any.new(user_removed) if user_removed
      result
    end

    private def ensure_present(
      db : DB::Database, name : String, existing_flags : Hash(String, Bool)?,
      password : String?, desired_flags : Hash(String, Bool)?, check_mode : Bool,
    ) : PluginResult
      queries = [] of String
      if existing_flags
        changed = update_existing_role(db, name, existing_flags, password, desired_flags, check_mode, queries)
      else
        # Ansible's user_add() records the CREATE template even under check
        # mode (the module is never executed, but the template is already
        # appended) - live-verified.
        queries << create_template(name, password, desired_flags)
        unless check_mode
          db.exec real_sql(queries.last, password)
        end
        changed = true
      end

      user_result(name, changed, queries)
    end

    # Ansible's own user_add() uses `CREATE USER`, not `CREATE
    # ROLE` - they're otherwise identical in Postgres, but `CREATE
    # USER` implies LOGIN by default while plain `CREATE ROLE`
    # defaults to NOLOGIN. Real bug found benchmarking
    # robertdebock.postgres (round 43): with no `role_attr_flags:`
    # given at all (the common case - most playbooks just want a
    # normal login-capable user), this plugin created a role that
    # couldn't log in at all, while Ansible's created one that
    # could - confirmed via `\du` showing "Cannot login" here vs.
    # empty attributes on Ansible's identically-configured run.
    private def create_template(
      name : String, password : String?, desired_flags : Hash(String, Bool)?,
    ) : String
      parts = ["CREATE USER #{quote_ident(name)}"]
      if password && !password.empty?
        parts << "WITH ENCRYPTED"
        parts << "PASSWORD %(password)s"
      end
      parts << (desired_flags ? PluginHelpers::PostgresqlRoleFlags.to_sql(desired_flags) : "")
      String.build { |str| parts.each_with_index { |part, i| str << ' ' if i > 0; str << part } }
    end

    # The statement actually sent: real interpolates the %(password)s
    # placeholder (plus encrypted/expires) via psycopg's parameter binding.
    private def real_sql(template : String, password : String?) : String
      return template unless password && !password.empty?
      template.gsub("%(password)s", quote_str(password))
    end

    private def update_existing_role(
      db : DB::Database, name : String, existing_flags : Hash(String, Bool),
      password : String?, desired_flags : Hash(String, Bool)?, check_mode : Bool,
      queries : Array(String),
    ) : Bool
      changed = false

      if password
        pw_changing = password_should_change?(db, name, password)
        if pw_changing
          queries << alter_password_template(name, password)
          unless check_mode
            db.exec real_sql(queries.last, password)
          end
          changed = true
        end
      end

      if desired_flags && flags_differ?(existing_flags, desired_flags)
        queries << "ALTER USER #{quote_ident(name)} WITH #{PluginHelpers::PostgresqlRoleFlags.to_sql(desired_flags)}"
        db.exec queries.last unless check_mode
        changed = true
      end

      changed
    end

    # Ansible's pwchanging ALTER template (postgresql_user.py:639-647):
    # 'ALTER USER "name"' + 'WITH ENCRYPTED' + 'PASSWORD %(password)s' +
    # the (possibly empty) role_attr_flags string.
    private def alter_password_template(name : String, password : String) : String
      String.build do |str|
        str << "ALTER USER " << quote_ident(name)
        if password.empty?
          str << " WITH PASSWORD NULL"
        else
          str << " WITH ENCRYPTED PASSWORD %(password)s"
        end
        str << ' '
      end
    end

    private def ensure_absent(db : DB::Database, name : String, exists : Bool, check_mode : Bool) : PluginResult
      return user_result(name, false, [] of String) unless exists

      # Ansible's check-mode absent path never reaches user_delete(), so
      # executed_queries stays empty while user_removed is still true
      # (postgresql_user.py:951-956); a real drop appends the DROP and
      # sets user_removed to the drop's own changed (965).
      queries = [] of String
      unless check_mode
        queries << "DROP USER #{quote_ident(name)}"
        db.exec queries.last
      end
      user_result(name, true, queries, true)
    end

    private def flags_differ?(existing : Hash(String, Bool), desired : Hash(String, Bool)) : Bool
      desired.any? { |flag, value| existing[flag]? != value }
    end

    # Ansible's user_should_we_change_password(): diff the desired
    # password against pg_authid.rolpassword (not pg_roles - the
    # verifier only lives there) so an unchanged repeat call is a no-op.
    # Like the Ansible module, a server that won't reveal the verifier (or
    # has no row for the role) makes the password count as different.
    private def password_should_change?(db : DB::Database, name : String, password : String) : Bool
      current_password = begin
        db.query_one? "SELECT rolpassword FROM pg_authid WHERE rolname = $1", name, as: String?
      rescue
        return true
      end

      server_encryption = begin
        db.scalar("SHOW password_encryption").as(String)
      rescue
        "scram-sha-256"
      end

      PluginHelpers::PostgresqlPasswordVerifier.needs_change?(current_password, password, name, server_encryption)
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
      PluginHelpers::SqlQuoting.pg_quote_ident(s)
    end

    private def quote_str(s : String) : String
      PluginHelpers::SqlQuoting.quote_str(s)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::PostgresqlUserPlugin.new(config)
plugin.run

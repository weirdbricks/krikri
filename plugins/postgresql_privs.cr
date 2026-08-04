#!/usr/bin/env crystal

require "json"
require "pg"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/postgresql_connection"
require "../src/crystal_play/plugin_helpers/postgresql_acl"

module CrystalPlay
  # PostgreSQL privileges plugin - grants/revokes GRANT/REVOKE-style
  # privileges on database objects. Compatible (for the object types
  # implemented - see below) with Ansible's
  # community.postgresql.postgresql_privs module.
  #
  # See plugins/postgresql_db.cr's module comment for the shared
  # architecture note (talks to the server directly over PostgreSQL's own
  # wire protocol via will/crystal-pg). Real Ansible splits this from role
  # management (postgresql_user, implemented separately in this codebase)
  # - this plugin follows the same split.
  #
  # Supported parameters:
  # - type: `table` (default) / `sequence` / `schema` / `database` - real
  #   Ansible's own module also supports `default_privs`/
  #   `foreign_data_wrapper`/`foreign_server`/`function`/`group`/
  #   `language`/`tablespace`/`type`/`procedure`/`parameter`; only the
  #   four most commonly used in real playbooks are implemented here, a
  #   documented scope cut (see below), not an oversight.
  # - objs: comma-separated list of object names `type` applies to
  #   (required for `table`/`sequence`/`schema`; for `database`, defaults
  #   to the connected database itself when omitted, matching real
  #   Ansible's own behavior - GRANT ON DATABASE almost always targets
  #   "whichever database this connection is for"). `ALL_IN_SCHEMA` isn't
  #   implemented - a documented scope cut.
  # - privs: comma-separated list of privilege names, or `ALL`/
  #   `ALL PRIVILEGES` (expands per `type` - see
  #   `PluginHelpers::PostgresqlAcl.all_privs`)
  # - roles: comma-separated list of role names to grant/revoke for, or
  #   `PUBLIC`
  # - state: `present` (default, GRANT) / `absent` (REVOKE)
  # - grant_option: when given, also grants/revokes `WITH GRANT OPTION`
  #   for exactly the privileges in `privs:` (real Ansible's own
  #   documented way to revoke just the grant option while keeping the
  #   privilege itself: `state: present` + `grant_option: false`) - when
  #   omitted, grant option is left untouched either way.
  # - schema: schema containing `objs` for `table:`/`sequence:` (default
  #   `"public"`, matching real Ansible's own default)
  # - login_host (default "localhost"), login_port (default 5432),
  #   login_user (default "postgres"), login_password,
  #   login_unix_socket, login_db (database to connect to - default
  #   "postgres", and also the target for `type: database` when `objs:`
  #   is omitted, per above)
  # - check_mode
  #
  # Idempotency is computed from the object's own real ACL array
  # (`relacl`/`nspacl`/`datacl`, cast to `::text` and parsed by
  # `PostgresqlAcl` - the same representation `\dp`/`\dn+`/`\l+` render),
  # not from a `has_*_privilege()` check - the latter would also return
  # true for a privilege a role only has *indirectly* (via PUBLIC or
  # group membership), which would wrongly skip a real, missing direct
  # GRANT. A missing/NULL ACL column (no explicit grants recorded on the
  # object yet) parses to "nothing granted", a documented simplification
  # (see `PostgresqlAcl.parse`) matching this codebase's general
  # tolerance for not chasing every inherited-privilege edge case exactly
  # (`postgresql_user.cr` already doesn't compare inherited role
  # membership either).
  #
  # Not implemented: `type: default_privs`/`foreign_data_wrapper`/
  # `foreign_server`/`function`/`group`/`language`/`tablespace`/`type`/
  # `procedure`/`parameter`, `ALL_IN_SCHEMA`, `target_roles:`,
  # `session_role:`, `fail_on_role:`, `trust_input:` (this plugin always
  # quotes identifiers itself instead), the granular `ssl_*` params (not
  # supported by any plugin in this codebase - `login_*` only).
  class PostgresqlPrivsPlugin < BasePlugin
    TYPES_WITH_SCHEMA = {"table", "sequence"}

    # Every parameter #execute needs, once parsed and validated -
    # bundling them lets #resolve_params! raise on the first problem it
    # finds and #execute stay a single begin/rescue instead of a chain of
    # `if error ... return` guards (ameba's cyclomatic-complexity budget).
    record ResolvedParams,
      type : String, state : String, privs : Array(String), roles : Array(String),
      objs : Array(String), schema : String, login_db : String,
      check_mode : Bool, grant_option : Bool?

    def execute : PluginResult
      begin
        p = resolve_params!
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: ex.message || "invalid parameters")
      end

      uri = PluginHelpers::PostgresqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]? || "postgres",
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        dbname: p.login_db,
      )

      DB.open(uri) do |database|
        changed = apply_all_grants(database, p.type, p.objs, p.schema, p.roles, p.privs, p.state, p.grant_option, p.check_mode)
        PluginResult.new(changed: changed, failed: false, msg: changed ? "Privileges updated" : "Privileges already up to date")
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the PostgreSQL server: #{ex.message}")
    rescue ex : PQ::PQError
      PluginResult.new(changed: false, failed: true, msg: "PostgreSQL error: #{ex.message}")
    end

    # Parses and validates every parameter, raising with a clear message
    # on the first problem found (caught by #execute).
    private def resolve_params! : ResolvedParams
      type = @params["type"]? || "table"
      state = @params["state"]? || "present"
      raise "type must be one of table, sequence, schema, database, got '#{type}'" unless PluginHelpers::PostgresqlAcl::PRIV_LETTERS.has_key?(type)
      raise "state must be 'present' or 'absent', got '#{state}'" unless state == "present" || state == "absent"

      privs_param = @params["privs"]?
      roles_param = @params["roles"]?
      raise "privs and roles are both required" unless privs_param && roles_param

      login_db = @params["login_db"]? || "postgres"
      schema = @params["schema"]? || "public"
      roles = roles_param.split(',').map(&.strip).reject(&.empty?)
      privs = PluginHelpers::PostgresqlAcl.resolve_privs(type, privs_param)
      objs = resolve_objs!(type, login_db)
      validate_identifiers!(schema, objs, roles)

      ResolvedParams.new(
        type: type, state: state, privs: privs, roles: roles, objs: objs, schema: schema, login_db: login_db,
        check_mode: is_true?(@params["check_mode"]?), grant_option: @params["grant_option"]?.try { |v| is_true?(v) },
      )
    end

    # objs: is required for table/sequence/schema; for database, it
    # defaults to the connected database itself when omitted (see the
    # class doc above for why). Raises (caught alongside
    # PostgresqlAcl.resolve_privs's own errors in #execute) rather than
    # returning nil, so the caller doesn't need an extra nil-check
    # branch just to get Array(String) instead of Array(String)?.
    private def resolve_objs!(type : String, login_db : String) : Array(String)
      objs = if raw = @params["objs"]?
               raw.split(',').map(&.strip).reject(&.empty?)
             elsif type == "database"
               [login_db]
             end

      raise "objs is required for type '#{type}'" if objs.nil? || objs.empty?
      objs
    end

    private def validate_identifiers!(schema : String, objs : Array(String), roles : Array(String))
      valid = identifier_safe?(schema) &&
              objs.all? { |obj| identifier_safe?(obj) } &&
              roles.all? { |role| role == "PUBLIC" || identifier_safe?(role) }

      raise "objs/roles/schema may only contain letters, digits, and underscores" unless valid
    end

    # Loops every (obj, role) pair, computing and applying each one's own
    # GRANT/REVOKE delta - split out of #execute to keep its own branch
    # count down (ameba's cyclomatic-complexity budget).
    private def apply_all_grants(
      db : DB::Database, type : String, objs : Array(String), schema : String, roles : Array(String),
      privs : Array(String), state : String, grant_option : Bool?, check_mode : Bool,
    ) : Bool
      changed = false

      objs.each do |obj|
        acl = PluginHelpers::PostgresqlAcl.parse(fetch_acl(db, type, obj, schema))

        roles.each do |role|
          changed |= apply_grants(db, type, obj, schema, role, privs, state, grant_option, acl, check_mode)
        end
      end

      changed
    end

    # Computes and (unless check_mode) applies the GRANT/REVOKE delta for
    # a single (obj, role) pair, returning whether anything changed.
    private def apply_grants(
      db : DB::Database, type : String, obj : String, schema : String, role : String,
      privs : Array(String), state : String, grant_option : Bool?, acl : Hash(String, Hash(Char, Bool)), check_mode : Bool,
    ) : Bool
      letters = privs.map { |priv| PluginHelpers::PostgresqlAcl.letter_for(type, priv) }
      to_grant, to_revoke, to_revoke_option = grant_delta(privs, letters, role, state, grant_option, acl)

      changed = !to_grant.empty? || !to_revoke.empty? || !to_revoke_option.empty?
      return changed if check_mode || !changed

      execute_grant_statements(db, type, obj, schema, role, to_grant, to_revoke, to_revoke_option, grant_option)
      changed
    end

    # All three possible statements (GRANT, REVOKE, REVOKE GRANT OPTION
    # FOR) are computed into their own lists *before* anything executes,
    # so #apply_grants's check_mode short-circuit and its returned
    # `changed` value both see the complete picture - a
    # `grant_option: false` request that only needs to strip an existing
    # privilege's grant option (the privilege itself staying granted)
    # doesn't touch to_grant/to_revoke at all, so it has to contribute to
    # `changed` on its own via to_revoke_option.
    private def grant_delta(
      privs : Array(String), letters : Array(Char), role : String,
      state : String, grant_option : Bool?, acl : Hash(String, Hash(Char, Bool)),
    ) : {Array(String), Array(String), Array(String)}
      to_grant = [] of String
      to_revoke = [] of String
      to_revoke_option = [] of String

      privs.zip(letters).each do |priv, letter|
        has_priv = PluginHelpers::PostgresqlAcl.has_privilege?(acl, role, letter)
        has_option = PluginHelpers::PostgresqlAcl.has_grant_option?(acl, role, letter)

        if state == "present"
          to_grant << priv unless has_priv
          # has_priv/!has_priv are mutually exclusive with the branch
          # above, so this can never add priv to to_grant twice.
          to_grant << priv if grant_option == true && has_priv && !has_option
        else
          to_revoke << priv if has_priv
        end

        to_revoke_option << priv if grant_option == false && has_option
      end

      {to_grant, to_revoke, to_revoke_option}
    end

    private def execute_grant_statements(
      db : DB::Database, type : String, obj : String, schema : String, role : String,
      to_grant : Array(String), to_revoke : Array(String), to_revoke_option : Array(String), grant_option : Bool?,
    )
      target = qualified_object(type, obj, schema)
      grantee = role == "PUBLIC" ? "PUBLIC" : quote_ident(role)

      unless to_grant.empty?
        option_clause = grant_option == true ? " WITH GRANT OPTION" : ""
        db.exec "GRANT #{to_grant.join(", ")} ON #{object_kind(type)} #{target} TO #{grantee}#{option_clause}"
      end

      unless to_revoke.empty?
        db.exec "REVOKE #{to_revoke.join(", ")} ON #{object_kind(type)} #{target} FROM #{grantee}"
      end

      unless to_revoke_option.empty?
        db.exec "REVOKE GRANT OPTION FOR #{to_revoke_option.join(", ")} ON #{object_kind(type)} #{target} FROM #{grantee}"
      end
    end

    private def object_kind(type : String) : String
      case type
      when "table"    then "TABLE"
      when "sequence" then "SEQUENCE"
      when "schema"   then "SCHEMA"
      when "database" then "DATABASE"
      else                 raise "unsupported type: #{type}"
      end
    end

    private def qualified_object(type : String, obj : String, schema : String) : String
      if TYPES_WITH_SCHEMA.includes?(type)
        "#{quote_ident(schema)}.#{quote_ident(obj)}"
      else
        quote_ident(obj)
      end
    end

    # Reads the object's ACL column as text (nil if the object itself
    # doesn't exist, surfaced as a clear failure by the caller's own
    # DB::ConnectionRefused/PQError rescues if the subsequent GRANT then
    # fails against a nonexistent object).
    private def fetch_acl(db : DB::Database, type : String, obj : String, schema : String) : String?
      case type
      when "table"
        db.query_one? <<-SQL, schema, obj, as: String?
          SELECT relacl::text FROM pg_class
          WHERE relname = $2 AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1)
        SQL
      when "sequence"
        db.query_one? <<-SQL, schema, obj, as: String?
          SELECT relacl::text FROM pg_class
          WHERE relname = $2 AND relkind = 'S' AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1)
        SQL
      when "schema"
        db.query_one? "SELECT nspacl::text FROM pg_namespace WHERE nspname = $1", obj, as: String?
      when "database"
        db.query_one? "SELECT datacl::text FROM pg_database WHERE datname = $1", obj, as: String?
      else
        raise "unsupported type: #{type}"
      end
    end

    private def identifier_safe?(value : String) : Bool
      !!value.matches?(/\A[A-Za-z0-9_]+\z/)
    end

    private def quote_ident(s : String) : String
      "\"" + s.gsub("\"", "\"\"") + "\""
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::PostgresqlPrivsPlugin.new(config)
plugin.run

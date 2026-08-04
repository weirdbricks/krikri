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
  # - type: `table` (default) / `sequence` / `schema` / `database` /
  #   `language` / `tablespace` / `type` / `foreign_data_wrapper` /
  #   `foreign_server` / `parameter` (PostgreSQL 15+ only - `pg_parameter_acl`
  #   doesn't exist before that; privs: `SET`/`ALTER_SYSTEM`, the latter
  #   mapped to the real two-word SQL privilege `ALTER SYSTEM` when
  #   building the GRANT/REVOKE statement, matching real Ansible's own
  #   privilege-name spelling and its own `'_'` -> `' '` substitution) /
  #   `group` (role membership - `GRANT role TO role`, not an ACL grant
  #   at all, so `privs:` isn't accepted for it at all, matching real
  #   Ansible's own validation; idempotency and `grant_option:` here mean
  #   membership presence/`WITH ADMIN OPTION` respectively, checked
  #   directly against `pg_auth_members` rather than any ACL array -
  #   group membership isn't stored as one). Real Ansible's own module
  #   also supports `default_privs`/`function`/`procedure`; those remain
  #   a documented scope cut (see below) - `default_privs` operates on
  #   `pg_default_acl` (future objects, not existing ones - a different
  #   mechanism entirely, not just another object type), and
  #   `function`/`procedure` need signature-aware `objs:` parsing
  #   (`name(arg_types)`) this plugin doesn't implement.
  # - objs: comma-separated list of object names `type` applies to
  #   (required for `table`/`sequence`/`schema`/`language`/`tablespace`/
  #   `type`; for `database`, defaults to the connected database itself
  #   when omitted, matching real Ansible's own behavior - GRANT ON
  #   DATABASE almost always targets "whichever database this connection
  #   is for"). The literal value `ALL_IN_SCHEMA` is supported for
  #   `table`/`sequence` only (real Ansible also allows it for
  #   `function`/`procedure`, not implemented here per above) - expands
  #   to every table/sequence currently in `schema:`, queried fresh each
  #   run (verified against real Ansible's own `relkind in ('r', 'v',
  #   'm', 'p', 'f')` filter for tables).
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
  # - schema: schema containing `objs` for `table:`/`sequence:`/`type:`
  #   (default `"public"`, matching real Ansible's own default) -
  #   `language:`/`tablespace:` aren't schema-qualified at all in real
  #   PostgreSQL (cluster-wide objects), matching real Ansible's own
  #   `obj_ids` construction.
  # - session_role: `SET ROLE "role"` immediately after connecting,
  #   before anything else - the specified role must already be one
  #   `login_user:` is a member of (a plain PostgreSQL server-side error
  #   otherwise, surfaced via this plugin's existing `PQError` rescue,
  #   not a custom message the way real Ansible's own
  #   `"Could not switch to role %s"` is - a minor scope cut, not a
  #   behavior difference in what actually happens).
  # - fail_on_role: bool, default `true` - when a role in `roles:`
  #   doesn't exist (checked via `pg_roles`, `PUBLIC` always considered
  #   to exist), `true` fails the whole task immediately (matching real
  #   Ansible's own default); `false` skips just that role and continues
  #   with whichever others do exist, same as real Ansible's own
  #   `module.warn(...)` + continue behavior. If none of the requested
  #   roles exist, `changed: false` with no error, matching real
  #   Ansible's own "nothing to do" exit.
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
  # Not implemented: `type: default_privs`/`function`/`procedure`,
  # `ALL_IN_SCHEMA` for `function`/`procedure` (not implemented at all,
  # per above), `target_roles:` (only meaningful for `default_privs`),
  # `trust_input:` (this plugin always quotes identifiers itself
  # instead), the granular `ssl_*` params (not supported by any plugin in
  # this codebase - `login_*` only).
  class PostgresqlPrivsPlugin < BasePlugin
    TYPES_WITH_SCHEMA   = {"table", "sequence", "type"}
    ALL_IN_SCHEMA_TYPES = {"table", "sequence"}

    # Every parameter #execute needs, once parsed and validated -
    # bundling them lets #resolve_params! raise on the first problem it
    # finds and #execute stay a single begin/rescue instead of a chain of
    # `if error ... return` guards (ameba's cyclomatic-complexity budget).
    # objs/roles_raw are only partly resolved here: `all_in_schema:`
    # objs (queried live) and role existence (checked against
    # `pg_roles`) both need an open DB connection, so that final
    # resolution happens in #execute after connecting, not here.
    record ResolvedParams,
      type : String, state : String, privs : Array(String), roles_raw : Array(String),
      objs : Array(String), all_in_schema : Bool, schema : String, login_db : String,
      check_mode : Bool, grant_option : Bool?, session_role : String?, fail_on_role : Bool

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
        if session_role = p.session_role
          database.exec %(SET ROLE "#{session_role.gsub('"', "\"\"")}")
        end

        run_grants(database, p)
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the PostgreSQL server: #{ex.message}")
    rescue ex : PQ::PQError
      PluginResult.new(changed: false, failed: true, msg: "PostgreSQL error: #{ex.message}")
    end

    # Resolves objs/roles against the live DB (needed for
    # all_in_schema:/role-existence, see ResolvedParams' own doc comment)
    # and applies the grants - split out of #execute to keep its own
    # branch count down (ameba's cyclomatic-complexity budget).
    private def run_grants(database : DB::Database, p : ResolvedParams) : PluginResult
      objs = p.all_in_schema ? all_objs_in_schema(database, p.type, p.schema) : p.objs
      roles = begin
        resolve_roles!(database, p.roles_raw, p.fail_on_role)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: ex.message || "invalid role")
      end
      return PluginResult.new(changed: false, failed: false, msg: "No valid roles provided, nothing to do") if roles.empty?

      changed = if p.type == "group"
                  apply_all_group_grants(database, objs, roles, p.state, p.grant_option, p.check_mode)
                else
                  apply_all_grants(database, p.type, objs, p.schema, roles, p.privs, p.state, p.grant_option, p.check_mode)
                end
      PluginResult.new(changed: changed, failed: false, msg: changed ? "Privileges updated" : "Privileges already up to date")
    end

    # Parses and validates every parameter, raising with a clear message
    # on the first problem found (caught by #execute).
    private def resolve_params! : ResolvedParams
      type = @params["type"]? || "table"
      state = @params["state"]? || "present"
      valid_types = PluginHelpers::PostgresqlAcl::PRIV_LETTERS.keys + ["group"]
      raise "type must be one of #{valid_types.join(", ")}, got '#{type}'" unless valid_types.includes?(type)
      raise "state must be 'present' or 'absent', got '#{state}'" unless state == "present" || state == "absent"

      privs_param = @params["privs"]?
      roles_param = @params["roles"]?
      raise "roles is required" unless roles_param

      privs = if type == "group"
                raise "privs is not allowed for type 'group'" if privs_param
                [] of String
              elsif privs_param
                PluginHelpers::PostgresqlAcl.resolve_privs(type, privs_param)
              else
                raise "privs is required for type '#{type}'"
              end

      login_db = @params["login_db"]? || "postgres"
      schema = @params["schema"]? || "public"
      roles_raw = roles_param.split(',').map(&.strip).reject(&.empty?)
      objs, all_in_schema = resolve_objs!(type, login_db)
      validate_identifiers!(schema, objs, roles_raw)

      ResolvedParams.new(
        type: type, state: state, privs: privs, roles_raw: roles_raw, objs: objs, all_in_schema: all_in_schema,
        schema: schema, login_db: login_db, check_mode: is_true?(@params["check_mode"]?),
        grant_option: @params["grant_option"]?.try { |v| is_true?(v) },
        session_role: @params["session_role"]?, fail_on_role: is_true?(@params["fail_on_role"]?, default: true),
      )
    end

    # objs: is required for table/sequence/schema/language/tablespace/
    # type; for database, it defaults to the connected database itself
    # when omitted (see the class doc above for why). `ALL_IN_SCHEMA`
    # (table/sequence only) is returned as `all_in_schema: true` with an
    # empty objs list - resolved live against the DB in #execute, not
    # here. Raises (caught alongside PostgresqlAcl.resolve_privs's own
    # errors in #execute) rather than returning nil, so the caller
    # doesn't need an extra nil-check branch just to get Array(String)
    # instead of Array(String)?.
    private def resolve_objs!(type : String, login_db : String) : {Array(String), Bool}
      objs_param = @params["objs"]?
      if objs_param == "ALL_IN_SCHEMA"
        raise "objs: ALL_IN_SCHEMA can only be used for type: table or sequence, got '#{type}'" unless ALL_IN_SCHEMA_TYPES.includes?(type)
        return {[] of String, true}
      end

      objs = if objs_param
               objs_param.split(',').map(&.strip).reject(&.empty?)
             elsif type == "database"
               [login_db]
             end

      raise "objs is required for type '#{type}'" if objs.nil? || objs.empty?
      {objs, false}
    end

    private def validate_identifiers!(schema : String, objs : Array(String), roles : Array(String))
      valid = identifier_safe?(schema) &&
              objs.all? { |obj| identifier_safe?(obj) } &&
              roles.all? { |role| role == "PUBLIC" || identifier_safe?(role) }

      raise "objs/roles/schema may only contain letters, digits, and underscores" unless valid
    end

    # Queries every table/sequence currently in schema, fresh each run -
    # real Ansible's own ALL_IN_SCHEMA behavior (dynamic membership, not
    # a fixed list captured once). relkind filter for tables matches real
    # Ansible's own query exactly (r/v/m/p/f - ordinary/view/materialized
    # view/partitioned/foreign tables), not just 'r'.
    private def all_objs_in_schema(db : DB::Database, type : String, schema : String) : Array(String)
      relkinds = type == "table" ? "'r', 'v', 'm', 'p', 'f'" : "'S'"
      db.query_all <<-SQL, schema, as: String
        SELECT c.relname FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN (#{relkinds})
        ORDER BY c.relname
      SQL
    end

    # Checks each requested role against pg_roles (PUBLIC always exists,
    # matching real Ansible's own is_implicit_role short-circuit).
    # fail_on_role: true raises immediately on the first missing role
    # (caught by #execute's own rescue right at the call site);
    # fail_on_role: false skips just that role and continues - #execute
    # treats an empty result as "nothing to do", matching real Ansible's
    # own behavior exactly.
    private def resolve_roles!(db : DB::Database, roles_raw : Array(String), fail_on_role : Bool) : Array(String)
      roles_raw.select do |role|
        next true if role == "PUBLIC"

        exists = db.query_one? "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = $1", role, as: Int32?
        next true if exists

        raise "Role '#{role}' does not exist" if fail_on_role
        false
      end
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
        db.exec "GRANT #{sql_priv_list(to_grant)} ON #{object_kind(type)} #{target} TO #{grantee}#{option_clause}"
      end

      unless to_revoke.empty?
        db.exec "REVOKE #{sql_priv_list(to_revoke)} ON #{object_kind(type)} #{target} FROM #{grantee}"
      end

      unless to_revoke_option.empty?
        db.exec "REVOKE GRANT OPTION FOR #{sql_priv_list(to_revoke_option)} ON #{object_kind(type)} #{target} FROM #{grantee}"
      end
    end

    # Real Ansible's own VALID_PRIVS spells the parameter: type's second
    # privilege `ALTER_SYSTEM` (an underscore, since a bare privilege
    # name can't contain a space) but the actual SQL keyword is the
    # two-word `ALTER SYSTEM` - swapped back here, the same
    # underscore-to-space substitution real Ansible's own query building
    # does (`','.join(privs).replace('_', ' ')`). A no-op for every
    # other privilege name in this codebase, none of which contain an
    # underscore.
    private def sql_priv_list(privs : Array(String)) : String
      privs.map(&.gsub('_', ' ')).join(", ")
    end

    # type: group is a fundamentally different SQL construct from every
    # other type above - `GRANT role TO role` (role membership, checked
    # against `pg_auth_members`), not `GRANT priv ON object TO role` (an
    # ACL entry on `relacl`/`nspacl`/etc.) - so it bypasses
    # PostgresqlAcl/apply_all_grants entirely rather than being shoehorned
    # into the privilege-letter machinery above. objs: here are the
    # group/role names being granted; roles: are the members receiving
    # membership in them (real Ansible's own naming, kept as-is even
    # though "objs"/"roles" read oddly for this one type).
    private def apply_all_group_grants(
      db : DB::Database, groups : Array(String), members : Array(String),
      state : String, grant_option : Bool?, check_mode : Bool,
    ) : Bool
      changed = false

      groups.each do |group|
        members.each do |member|
          changed |= apply_group_grant(db, group, member, state, grant_option, check_mode)
        end
      end

      changed
    end

    private def apply_group_grant(
      db : DB::Database, group : String, member : String,
      state : String, grant_option : Bool?, check_mode : Bool,
    ) : Bool
      is_member, has_admin = group_membership(db, group, member)

      if state == "present"
        apply_group_grant_present(db, group, member, grant_option, is_member, has_admin, check_mode)
      else
        return false unless is_member
        return true if check_mode

        db.exec %(REVOKE #{quote_ident(group)} FROM #{quote_ident(member)})
        true
      end
    end

    private def apply_group_grant_present(
      db : DB::Database, group : String, member : String, grant_option : Bool?,
      is_member : Bool, has_admin : Bool, check_mode : Bool,
    ) : Bool
      needs_grant = !is_member || (grant_option == true && !has_admin)
      needs_revoke_admin = !needs_grant && grant_option == false && has_admin
      return false unless needs_grant || needs_revoke_admin
      return true if check_mode

      if needs_grant
        option_clause = grant_option == true ? " WITH ADMIN OPTION" : ""
        db.exec %(GRANT #{quote_ident(group)} TO #{quote_ident(member)}#{option_clause})
      else
        db.exec %(REVOKE ADMIN OPTION FOR #{quote_ident(group)} FROM #{quote_ident(member)})
      end
      true
    end

    # {is_member, has_admin_option} for (group, member) - queried
    # directly against pg_auth_members (verified against a real
    # PostgreSQL 17 server: no rows at all means not a member, exactly
    # one row with admin_option true/false otherwise), not derived from
    # any ACL array - group membership isn't stored as an aclitem[] at
    # all, unlike every other type this plugin handles.
    private def group_membership(db : DB::Database, group : String, member : String) : {Bool, Bool}
      admin_option = db.query_one? <<-SQL, group, member, as: Bool?
        SELECT am.admin_option FROM pg_catalog.pg_auth_members am
        JOIN pg_catalog.pg_roles g ON g.oid = am.roleid
        JOIN pg_catalog.pg_roles m ON m.oid = am.member
        WHERE g.rolname = $1 AND m.rolname = $2
      SQL

      {!admin_option.nil?, admin_option == true}
    end

    # Maps our own snake_case type: value to the actual SQL keyword(s)
    # GRANT/REVOKE ON expects - a plain lookup table rather than a
    # case/when chain (ameba's cyclomatic-complexity budget counts each
    # `when` as a branch; a Hash literal isn't branching at all).
    OBJECT_KINDS = {
      "table" => "TABLE", "sequence" => "SEQUENCE", "schema" => "SCHEMA", "database" => "DATABASE",
      "language" => "LANGUAGE", "tablespace" => "TABLESPACE", "type" => "TYPE",
      "foreign_data_wrapper" => "FOREIGN DATA WRAPPER", "foreign_server" => "FOREIGN SERVER",
      "parameter" => "PARAMETER",
    }

    private def object_kind(type : String) : String
      OBJECT_KINDS[type]? || raise "unsupported type: #{type}"
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
    # {acl_column, table_name, name_column} for every type whose ACL
    # lookup is a plain "single row by name" query - everything except
    # table/sequence/type below, which each need a real join/extra
    # WHERE clause instead of a single name match. table/column names
    # here are fixed Postgres catalog names hardcoded by this table
    # itself, never user input - only obj (always a $1 bind parameter)
    # comes from outside.
    SIMPLE_ACL_QUERIES = {
      "schema"     => {"nspacl", "pg_namespace", "nspname"},
      "database"   => {"datacl", "pg_database", "datname"},
      "language"   => {"lanacl", "pg_language", "lanname"},
      "tablespace" => {"spcacl", "pg_tablespace", "spcname"},

      "foreign_data_wrapper" => {"fdwacl", "pg_foreign_data_wrapper", "fdwname"},
      "foreign_server"       => {"srvacl", "pg_foreign_server", "srvname"},
      "parameter"            => {"paracl", "pg_parameter_acl", "parname"},
    }

    private def fetch_acl(db : DB::Database, type : String, obj : String, schema : String) : String?
      case type
      when "table"
        fetch_relacl(db, schema, obj, sequence_only: false)
      when "sequence"
        fetch_relacl(db, schema, obj, sequence_only: true)
      when "type"
        db.query_one? <<-SQL, schema, obj, as: String?
          SELECT t.typacl::text FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
          WHERE n.nspname = $1 AND t.typname = $2
        SQL
      else
        acl_column, table_name, name_column = SIMPLE_ACL_QUERIES[type]? || raise "unsupported type: #{type}"
        db.query_one? "SELECT #{acl_column}::text FROM #{table_name} WHERE #{name_column} = $1", obj, as: String?
      end
    end

    private def fetch_relacl(db : DB::Database, schema : String, obj : String, sequence_only : Bool) : String?
      relkind_clause = sequence_only ? "AND relkind = 'S' " : ""
      db.query_one? <<-SQL, schema, obj, as: String?
        SELECT relacl::text FROM pg_class
        WHERE relname = $2 #{relkind_clause}AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1)
      SQL
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

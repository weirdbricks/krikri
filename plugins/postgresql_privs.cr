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
  #   group membership isn't stored as one) / `function` / `procedure`
  #   (privs: `EXECUTE`; PostgreSQL 11+ for procedures, which is when
  #   `pg_proc.prokind` distinguishing them was added - see the `objs:`
  #   notes below for how signatures are written) / `default_privs`
  #   (ALTER DEFAULT PRIVILEGES - the privileges objects will receive
  #   *when created in future*, stored in `pg_default_acl` rather than on
  #   any existing object; see its own notes below).
  # - objs: comma-separated list of object names `type` applies to
  #   (required for `table`/`sequence`/`schema`/`language`/`tablespace`/
  #   `type`; for `database`, defaults to the connected database itself
  #   when omitted, matching real Ansible's own behavior - GRANT ON
  #   DATABASE almost always targets "whichever database this connection
  #   is for"). The literal value `ALL_IN_SCHEMA` is supported for
  #   `table`/`sequence`/`function`/`procedure` - expands to every such
  #   object currently in `schema:`, queried fresh each run (verified
  #   against real Ansible's own `relkind in ('r', 'v', 'm', 'p', 'f')`
  #   filter for tables, and its own `prokind` filter for routines).
  #
  #   For `function`/`procedure`, each obj must be a *signature*, not a
  #   bare name - `f(int)`, not `f` - because PostgreSQL allows
  #   overloading and a bare name cannot identify one. Anything without
  #   parentheses is rejected with real Ansible's own message
  #   ("Illegal function / procedure signature"). Since `objs:` is
  #   itself comma-separated, argument types are separated with **colons**
  #   rather than commas: `objs: "f(int:text)"` means `f(int, text)`.
  #   That is real Ansible's own encoding, applied the same way (after
  #   the comma split, not before). Type names are resolved by
  #   PostgreSQL, so aliases work exactly as they do in psql - `int` and
  #   `integer` name the same function.
  #   For `default_privs`, `objs:` means something different again: an
  #   object *class*, not an object name - `TABLES`, `SEQUENCES`,
  #   `FUNCTIONS`, `TYPES` or `SCHEMAS`. `ALL_DEFAULT` expands to the
  #   first four (deliberately not `SCHEMAS`, matching real Ansible,
  #   which pops it from that set). `state: absent` revokes across
  #   TABLES/FUNCTIONS/SEQUENCES/TYPES regardless of what `objs:` said,
  #   again matching real Ansible's own build_absent, which ignores objs
  #   entirely for this type.
  #
  #   Note `objs: SCHEMAS` cannot be combined with `schema:`: PostgreSQL
  #   rejects "IN SCHEMA ... ON SCHEMAS" outright ("cannot use IN SCHEMA
  #   clause when using GRANT/REVOKE ON SCHEMAS"). Since `schema:`
  #   defaults to "public", SCHEMAS is effectively unusable here - real
  #   Ansible has exactly the same limitation and fails with the same
  #   server error, verified side by side.
  # - target_roles: comma-separated roles whose future objects the
  #   default privileges apply to (the `FOR ROLE` clause). Only valid
  #   with `type: default_privs`, and rejected with a clear message
  #   otherwise. When omitted, ALTER DEFAULT PRIVILEGES applies to the
  #   role executing it, which is what `pg_default_acl.defaclrole`
  #   records and therefore what idempotency is checked against.
  # - privs: comma-separated list of privilege names, or `ALL`/
  #   `ALL PRIVILEGES` (expands per `type` - see
  #   `PluginHelpers::PostgresqlAcl.all_privs`). For `default_privs` the
  #   list is passed to PostgreSQL verbatim (so `ALL` stays `ALL` in the
  #   emitted SQL, as real Ansible does); it is expanded to letters only
  #   for the idempotency check, per object class, since `ALL` means
  #   different privileges for TABLES than for SEQUENCES.
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
  # `default_privs` idempotency deliberately differs in *mechanism* from
  # real Ansible while matching it in result: real Ansible executes its
  # statements unconditionally and reports `changed` by diffing
  # `pg_default_acl` before and after, which cannot support check_mode
  # (it would have to make the change to find out). Here the current
  # `defaclacl` is read and compared against the desired state first, so
  # `--check` works and no statement runs when nothing needs changing.
  # `state: present` remains declarative either way - it emits the same
  # REVOKE ALL + GRANT pair real Ansible does, so afterwards the grantee
  # holds exactly `privs:`, not the union with whatever was there before.
  #
  # Not implemented: `trust_input:` (this plugin always
  # quotes identifiers itself instead - and for routines defers to
  # PostgreSQL's own `regprocedure` parsing, see #resolve_routine), the
  # granular `ssl_*` params (not supported by any plugin in this
  # codebase - `login_*` only).
  #
  # One deliberate difference from real Ansible: `login_db:` is optional
  # here (defaults to "postgres"), where real Ansible's module lists it
  # as required and fails with "missing required arguments: login_db".
  # Longstanding behavior of this plugin, not introduced with routines.
  class PostgresqlPrivsPlugin < BasePlugin
    TYPES_WITH_SCHEMA   = {"table", "sequence", "type"}
    ALL_IN_SCHEMA_TYPES = {"table", "sequence", "function", "procedure"}
    # Routines live in pg_proc and are identified by *signature*, not by
    # a bare name - see #resolve_routine.
    ROUTINE_TYPES = {"function", "procedure"}

    # type: default_privs - the object *classes* ALTER DEFAULT PRIVILEGES
    # accepts, mapped to {pg_default_acl.defaclobjtype, the object type
    # whose privilege letters they share}. Reusing the existing letter
    # tables is exact, not an approximation: a default privilege for
    # TABLES is recorded with the same letters an actual table ACL uses.
    DEFAULT_OBJ_CLASSES = {
      "TABLES"    => {'r', "table"},
      "SEQUENCES" => {'S', "sequence"},
      "FUNCTIONS" => {'f', "function"},
      "TYPES"     => {'T', "type"},
      "SCHEMAS"   => {'n', "schema"},
    }

    # objs: ALL_DEFAULT expands to these four - deliberately *not*
    # SCHEMAS, matching real Ansible, which pops it from the set.
    ALL_DEFAULT_CLASSES = ["TABLES", "SEQUENCES", "FUNCTIONS", "TYPES"]

    # state: absent for default_privs revokes on this fixed list
    # regardless of what objs: said - real Ansible's own build_absent
    # ignores objs entirely for this type. SCHEMAS is absent here too.
    ABSENT_DEFAULT_CLASSES = ["TABLES", "FUNCTIONS", "SEQUENCES", "TYPES"]

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
      check_mode : Bool, grant_option : Bool?, session_role : String?, fail_on_role : Bool,
      target_roles : Array(String)

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

      objs = begin
        canonical_routines(database, p, objs)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: ex.message || "could not resolve routine")
      end

      roles = begin
        resolve_roles!(database, p.roles_raw, p.fail_on_role)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: ex.message || "invalid role")
      end
      return PluginResult.new(changed: false, failed: false, msg: "No valid roles provided, nothing to do") if roles.empty?

      changed = if p.type == "default_privs"
                  apply_all_default_privs(database, p, roles)
                elsif p.type == "group"
                  apply_all_group_grants(database, objs, roles, p.state, p.grant_option, p.check_mode)
                else
                  apply_all_grants(database, p.type, objs, p.schema, roles, p.privs, p.state, p.grant_option, p.check_mode)
                end
      PluginResult.new(changed: changed, failed: false, msg: changed ? "Privileges updated" : "Privileges already up to date")
    end

    # Routine references are canonicalized once, up front, into the
    # fully-qualified signatures PostgreSQL itself renders; everything
    # downstream (ACL lookup, GRANT target) then works with those and
    # never re-parses user input. ALL_IN_SCHEMA already produces them in
    # this form, so it is passed through untouched, as is every
    # non-routine type.
    private def canonical_routines(db : DB::Database, p : ResolvedParams, objs : Array(String)) : Array(String)
      return objs if p.all_in_schema || !ROUTINE_TYPES.includes?(p.type)

      objs.map { |obj| resolve_routine(db, p.type, obj, p.schema)[0] }
    end

    # Parses and validates every parameter, raising with a clear message
    # on the first problem found (caught by #execute).
    # privs: for default_privs is deliberately NOT expanded the way every
    # other type's is: ALTER DEFAULT PRIVILEGES takes the privilege list
    # verbatim, so `ALL` stays `ALL` in the emitted SQL (real Ansible
    # does the same - "we don't want privs to be quoted here").
    # Expansion to letters happens per object class at apply time, since
    # ALL means different privileges for TABLES than for SEQUENCES.
    private def default_privs_list(privs_param : String?) : Array(String)
      raise "privs is required for type 'default_privs'" unless privs_param
      privs_param.split(',').map(&.strip.upcase).reject(&.empty?)
    end

    # objs: for default_privs are object *classes*, not object names.
    private def default_privs_classes(objs_param : String?) : Array(String)
      raise "objs is required for type 'default_privs'" unless objs_param

      classes = if objs_param.strip.upcase == "ALL_DEFAULT"
                  ALL_DEFAULT_CLASSES.dup
                else
                  objs_param.split(',').map(&.strip.upcase).reject(&.empty?)
                end

      classes.each do |cls|
        unless DEFAULT_OBJ_CLASSES.has_key?(cls)
          raise "objs for type 'default_privs' must be one of #{DEFAULT_OBJ_CLASSES.keys.join(", ")} or ALL_DEFAULT, got '#{cls}'"
        end
      end
      raise "objs is required for type 'default_privs'" if classes.empty?

      classes
    end

    # Each type spells "which privileges" differently: group takes none
    # at all, default_privs passes them through verbatim, everything else
    # expands ALL against that type's own privilege set.
    private def resolve_privs_for(type : String, privs_param : String?) : Array(String)
      case type
      when "group"
        raise "privs is not allowed for type 'group'" if privs_param
        [] of String
      when "default_privs"
        default_privs_list(privs_param)
      else
        raise "privs is required for type '#{type}'" unless privs_param
        PluginHelpers::PostgresqlAcl.resolve_privs(type, privs_param)
      end
    end

    private def resolve_target_roles!(type : String) : Array(String)
      roles = (@params["target_roles"]? || "").split(',').map(&.strip).reject(&.empty?)
      raise "target_roles is only supported for type: default_privs" if !roles.empty? && type != "default_privs"

      roles
    end

    private def resolve_params! : ResolvedParams
      type = @params["type"]? || "table"
      state = @params["state"]? || "present"
      valid_types = PluginHelpers::PostgresqlAcl::PRIV_LETTERS.keys + ["group", "default_privs"]
      raise "type must be one of #{valid_types.join(", ")}, got '#{type}'" unless valid_types.includes?(type)
      raise "state must be 'present' or 'absent', got '#{state}'" unless state == "present" || state == "absent"

      privs_param = @params["privs"]?
      roles_param = @params["roles"]?
      raise "roles is required" unless roles_param

      privs = resolve_privs_for(type, privs_param)

      login_db = @params["login_db"]? || "postgres"
      schema = @params["schema"]? || "public"
      roles_raw = roles_param.split(',').map(&.strip).reject(&.empty?)
      target_roles = resolve_target_roles!(type)

      objs, all_in_schema = resolve_objs!(type, login_db)
      skip_obj_check = ROUTINE_TYPES.includes?(type) || type == "default_privs"
      validate_identifiers!(schema, skip_obj_check ? [] of String : objs, roles_raw)

      ResolvedParams.new(
        type: type, state: state, privs: privs, roles_raw: roles_raw, objs: objs, all_in_schema: all_in_schema,
        target_roles: target_roles,
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

      return {default_privs_classes(objs_param), false} if type == "default_privs"

      if objs_param == "ALL_IN_SCHEMA"
        raise "objs: ALL_IN_SCHEMA can only be used for type: table, sequence, function or procedure, got '#{type}'" unless ALL_IN_SCHEMA_TYPES.includes?(type)
        return {[] of String, true}
      end

      objs = if objs_param
               parsed = objs_param.split(',').map(&.strip).reject(&.empty?)
               # Routine signatures are encoded with ':' between argument
               # types, because objs: itself is comma-separated - without
               # this convention `f(int, text)` would split into the two
               # nonsense objects `f(int` and `text)`. Real Ansible uses
               # exactly the same encoding, and applies it after the
               # comma split, not before: `obj.replace(':', ',')`.
               parsed = parsed.map(&.gsub(':', ',')) if ROUTINE_TYPES.includes?(type)
               parsed
             elsif type == "database"
               [login_db]
             end

      raise "objs is required for type '#{type}'" if objs.nil? || objs.empty?

      # Real Ansible requires the `name(args)` form for routines and
      # raises on anything else, rather than trying to resolve a bare
      # name - PostgreSQL's own regprocedure input requires the argument
      # list too ("expected a left parenthesis"), so a bare name could
      # only ever work by guessing at overloads. Same message it uses.
      if ROUTINE_TYPES.includes?(type)
        objs.each do |obj|
          raise "Illegal function / procedure signature: \"#{obj}\"." unless obj.includes?('(')
        end
      end

      {objs, false}
    end

    # Routine objs: are deliberately exempt (passed as an empty list by
    # the caller): a signature legitimately contains parentheses, commas,
    # spaces and dots (`f(character varying, public.mytype)`), none of
    # which this identifier check allows. They are validated instead by
    # PostgreSQL itself, via the bound `regprocedure` cast in
    # #resolve_routine - which is stricter than this check, not weaker,
    # since a reference that does not resolve to a real routine fails
    # outright. schema:/roles: are still checked here for them.
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
      # Routines come back as fully-qualified signatures, the same form
      # #resolve_routine produces, so overloads are addressed
      # individually rather than collapsing to one ambiguous bare name.
      if ROUTINE_TYPES.includes?(type)
        return db.query_all <<-SQL, schema, PROKINDS[type].to_s, as: String
          SELECT quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' ||
                   coalesce((SELECT string_agg(format_type(t, NULL), ', ' ORDER BY ord)
                             FROM unnest(p.proargtypes) WITH ORDINALITY AS a(t, ord)), '') || ')'
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = $1 AND p.prokind = $2::"char"
          ORDER BY 1
        SQL
      end

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

    # type: default_privs - ALTER DEFAULT PRIVILEGES, which controls the
    # privileges objects will get *when they are created in future*, not
    # the privileges of anything that exists now. It is stored in
    # `pg_default_acl` rather than on any object, so none of the
    # fetch_acl/qualified_object machinery above applies; this is a
    # parallel path, not another object type.
    #
    # Real Ansible executes its statements unconditionally and reports
    # `changed` by diffing `pg_default_acl` before and after. That cannot
    # support check_mode (it would have to actually make the change to
    # find out), so idempotency here is computed *predictively* from the
    # current defaclacl instead - the same approach the rest of this
    # plugin already takes for ordinary ACLs, and it produces the same
    # changed/unchanged answer.
    #
    # `state: present` is declarative, matching real Ansible's own
    # REVOKE-ALL-then-GRANT pair: afterwards the grantee holds exactly
    # `privs` for that class, no more. So "already correct" means the
    # current letter set equals the desired one, not merely contains it.
    private def apply_all_default_privs(db : DB::Database, p : ResolvedParams, roles : Array(String)) : Bool
      # With no target_roles:, ALTER DEFAULT PRIVILEGES applies to the
      # role running the statement, which is what pg_default_acl records
      # in defaclrole - so that is what idempotency must be checked
      # against.
      owners = p.target_roles.empty? ? [current_role(db)] : p.target_roles

      # state: absent revokes across a fixed class list regardless of
      # objs:, exactly as real Ansible's own build_absent does.
      classes = p.state == "absent" ? ABSENT_DEFAULT_CLASSES : p.objs

      changed = false
      owners.each do |owner|
        classes.each do |cls|
          roles.each do |role|
            changed = true if apply_default_priv(db, p, owner, cls, role)
          end
        end
      end
      changed
    end

    # One {owner, class, grantee} triple. Returns whether anything needed
    # changing (and, unless check_mode, changed it).
    private def apply_default_priv(db : DB::Database, p : ResolvedParams, owner : String, cls : String, role : String) : Bool
      objtype, letter_type = DEFAULT_OBJ_CLASSES[cls]

      desired = if p.state == "absent"
                  [] of String
                elsif p.privs.includes?("ALL") || p.privs.includes?("ALL PRIVILEGES")
                  PluginHelpers::PostgresqlAcl.all_privs(letter_type)
                else
                  p.privs
                end

      # Validate against the class, not the type: FUNCTIONS only accepts
      # EXECUTE, TYPES only USAGE, and so on.
      desired.each do |priv|
        PluginHelpers::PostgresqlAcl.letter_for(letter_type, priv)
      end

      parsed = PluginHelpers::PostgresqlAcl.parse(fetch_default_acl(db, owner, p.schema, objtype))
      grantee = role == "PUBLIC" ? "" : role
      current = PluginHelpers::PostgresqlAcl.all_privs(letter_type).select do |priv|
        PluginHelpers::PostgresqlAcl.has_privilege?(parsed, grantee, PluginHelpers::PostgresqlAcl.letter_for(letter_type, priv))
      end

      return false if current.to_set == desired.to_set
      return true if p.check_mode

      execute_default_priv_statements(db, p, owner, cls, role, desired)
      true
    end

    private def execute_default_priv_statements(
      db : DB::Database, p : ResolvedParams, owner : String, cls : String, role : String, desired : Array(String),
    )
      grantee = role == "PUBLIC" ? "PUBLIC" : quote_ident(role)
      # target_roles: is only emitted when it was actually given - with no
      # FOR ROLE clause the statement implicitly applies to the current
      # role, which is what owner already resolved to.
      for_role = p.target_roles.empty? ? "" : " FOR ROLE #{quote_ident(owner)}"
      in_schema = " IN SCHEMA #{quote_ident(p.schema)}"

      # REVOKE ALL first, so the end state is exactly `desired` rather
      # than the union of desired and whatever was there before - real
      # Ansible pairs the same two statements for state: present.
      db.exec "ALTER DEFAULT PRIVILEGES#{for_role}#{in_schema} REVOKE ALL ON #{cls} FROM #{grantee}"
      return if desired.empty?

      option = p.grant_option == true ? " WITH GRANT OPTION" : ""
      db.exec "ALTER DEFAULT PRIVILEGES#{for_role}#{in_schema} GRANT #{sql_priv_list(desired)} ON #{cls} TO #{grantee}#{option}"
    end

    private def fetch_default_acl(db : DB::Database, owner : String, schema : String, objtype : Char) : String?
      db.query_one? <<-SQL, owner, schema, objtype.to_s, as: String?
        SELECT a.defaclacl::text
        FROM pg_default_acl a
        JOIN pg_roles r ON r.oid = a.defaclrole
        JOIN pg_namespace n ON n.oid = a.defaclnamespace
        WHERE r.rolname = $1 AND n.nspname = $2 AND a.defaclobjtype = $3::"char"
      SQL
    end

    private def current_role(db : DB::Database) : String
      db.query_one "SELECT current_user", as: String
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
      "function" => "FUNCTION", "procedure" => "PROCEDURE",
    }

    # pg_proc.prokind for each routine type: 'f' ordinary function,
    # 'p' procedure. Aggregates ('a') and window functions ('w') are
    # deliberately not addressable - real Ansible's module doesn't expose
    # them either.
    PROKINDS = {"function" => 'f', "procedure" => 'p'}

    private def object_kind(type : String) : String
      OBJECT_KINDS[type]? || raise "unsupported type: #{type}"
    end

    private def qualified_object(type : String, obj : String, schema : String) : String
      # function/procedure are resolved through the server itself (see
      # #resolve_routine) and arrive here already fully qualified and
      # correctly quoted, signature included - re-quoting would produce
      # `"public.f(integer)"` as a single identifier.
      return obj if ROUTINE_TYPES.includes?(type)

      if TYPES_WITH_SCHEMA.includes?(type)
        "#{quote_ident(schema)}.#{quote_ident(obj)}"
      else
        quote_ident(obj)
      end
    end

    # Resolves one user-supplied routine reference - `myfunc`, or
    # `myfunc(int, text)` when overloads make the bare name ambiguous -
    # to `{qualified_signature, proacl}`.
    #
    # The signature is *never* interpolated from user input. It is bound
    # as a parameter and cast to `regprocedure`, so PostgreSQL's own
    # parser resolves it and PostgreSQL's own `pg_get_function_identity_
    # arguments` renders the canonical argument list back. That both
    # removes any injection surface (the alternative - splitting
    # `name(a, b)` in Crystal and interpolating the pieces - would have
    # to hand-parse types like `character varying`, `int[]` and
    # `public.mytype`) and makes overload resolution and type aliasing
    # exactly PostgreSQL's, not an approximation of it: `int` and
    # `integer` resolve to the same function, as they do in psql.
    #
    # Errors from the cast (no such function, ambiguous bare name) are
    # PostgreSQL's own, surfaced through #execute's PQError rescue.
    #
    # The signature is rendered from `proargtypes` via `format_type`
    # rather than the more obvious `pg_get_function_identity_arguments`,
    # because that function includes argument *names* and modes
    # (`f1(a integer)`, `p1(IN a integer)`). GRANT accepts that form, but
    # `regprocedure` input does not - it would fail with "syntax error at
    # or near \"integer\"" when the same string is later used to look the
    # ACL back up. `proargtypes` yields `f1(integer)`, which is valid for
    # both, and covers exactly the IN/INOUT arguments that identify a
    # routine (OUT arguments are correctly excluded).
    private def resolve_routine(db : DB::Database, type : String, obj : String, schema : String) : {String, String?}
      reference = obj.includes?('.') ? obj : "#{schema}.#{obj}"
      wanted = PROKINDS[type]

      row = db.query_one? <<-SQL, reference, as: {String, String, String?}
        SELECT
          quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' ||
            coalesce((SELECT string_agg(format_type(t, NULL), ', ' ORDER BY ord)
                      FROM unnest(p.proargtypes) WITH ORDINALITY AS a(t, ord)), '') || ')',
          p.prokind::text,
          p.proacl::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.oid = $1::regprocedure
      SQL

      raise "#{type} '#{obj}' not found in schema '#{schema}'" unless row
      signature, prokind, acl = row

      # A procedure addressed as a function (or vice versa) would
      # otherwise produce a confusing server-side syntax error from the
      # GRANT itself, since the object exists but under the other keyword.
      unless prokind == wanted.to_s
        actual = PROKINDS.key_for?(prokind[0]?) || "routine of kind '#{prokind}'"
        raise "'#{obj}' is a #{actual}, not a #{type}"
      end

      {signature, acl}
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
      when "function", "procedure"
        # obj is already the canonical signature run_grants resolved, so
        # the regprocedure cast here is an exact-match lookup, not
        # overload resolution.
        db.query_one? "SELECT p.proacl::text FROM pg_proc p WHERE p.oid = $1::regprocedure", obj, as: String?
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

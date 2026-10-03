#!/usr/bin/env crystal

require "json"
require "pg"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/postgresql_connection"
require "../src/krikri/plugin_helpers/postgresql_query_heuristics"

module Krikri
  # postgresql_query plugin (community.postgresql.postgresql_query) -
  # runs SQL against PostgreSQL over the wire protocol through the same
  # shared PostgresqlConnection helper as the other community.postgresql
  # plugins (crystal-pg standing in for psycopg2). Params:
  # - login_db: database to connect to. NOT required in the live module
  #   (community.postgresql 4.x dropped required=True; with neither
  #   login_db given, psycopg2 connects to the default database). The
  #   deprecated `db:` spelling IS still accepted as an alias of
  #   login_db (it is in the real 4.2.0 argument_spec, with a
  #   deprecation warning - live-verified by running real 2.19.11).
  # - query: SQL string, or a JSON-encoded list of statements run in
  #   order (the real module's list form). Also not required: real's
  #   argument_spec has no required=True on query, and a nil query
  #   crashes the module body's statement loop after connecting (an
  #   uncaught TypeError) - emulated here as a failed result, which
  #   matches the failed=True shape either way.
  # - positional_args: JSON list of $1-style binds; named_args: JSON
  #   dict of %(name)s binds (each statement's placeholders expanded to
  #   $N positions - crystal-pg has no named binding). Mutually
  # - login_host/login_port/login_user/login_password/login_unix_socket
  #   plus the deprecated host/port/login/unix_socket aliases (all in
  #   the real module's argument_spec - the same shared spec the other
  #   plugins use, so they resolve to identical values).
  # - autocommit: for statements that can't run in a transaction block
  #   (VACUUM). Mutually exclusive with check_mode.
  # - search_path: SET search_path before the query.
  # - check_mode: the query runs, but inside a transaction that is
  #   rolled back at the end (matching the real module's
  #   execute-then-rollback).
  #
  # Argument-validation surface matches the real module's AnsibleModule
  # setup (verified against the live collection via the podman-diff
  # postgresql_query case file): mutually-exclusive positional|named,
  # login_port int conversion, autocommit/trust_input bool conversion,
  # ssl_mode choices, and unsupported params LAST with the trailing
  # all-aliases parenthetical. The deprecated host/port/login/
  # unix_socket/db names are real aliases of the login_* params, so
  # they're accepted and resolve to the same values (live-verified by
  # running real 2.19.11 + community.postgresql 4.2.0).
  #
  # Returns, in real Ansible's own key order: changed, query (the LAST
  # statement, mogrify'd), query_list, statusmessage, query_result (the
  # LAST statement's full result set as an array of column->value dicts,
  # matching real Ansible - one entry per row, {} for a statement that
  # produces no rows), query_all_results (one row-list per statement),
  # rowcount (total produced/affected rows), execution_time_ms (per
  # statement), and the controller-backfilled failed: false. No msg on
  # success. Live-verified against real ansible-core 2.19.11 +
  # community.postgresql 4.2.0.
  #
  # Divergence, deliberate: statusmessage is synthesized from the
  # statement's leading keyword + affected-row count ("INSERT 0 1" /
  # "SELECT 3" style) - crystal-pg does not surface the server's raw
  # command tag. The real module's own changed: determination only ever
  # reads that tag's keyword and trailing count, and that rule is ported
  # exactly (see PostgresqlQueryHeuristics), so changed: itself matches.
  class PostgresqlQueryPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    private record RunOutcome,
      last_sql : String,
      last_result : JSON::Any,
      all_results : Array(JSON::Any),
      rowcount : Int64,
      statusmessage : String,
      changed : Bool,
      execution_times_ms : Array(Float64)

    # The real module's merged argument_spec (postgres_common_
    # argument_spec + postgresql_query's own update) in declaration
    # order - values are the spec's aliases.
    SPEC = {
      "login_user"        => ["login"],
      "login_password"    => [] of String,
      "login_host"        => ["host"],
      "login_unix_socket" => ["unix_socket"],
      "login_port"        => ["port"],
      "ssl_mode"          => [] of String,
      "ca_cert"           => ["ssl_rootcert"],
      "ssl_cert"          => [] of String,
      "ssl_key"           => [] of String,
      "connect_params"    => [] of String,
      "query"             => [] of String,
      "login_db"          => ["db"],
      "positional_args"   => [] of String,
      "named_args"        => [] of String,
      "session_role"      => [] of String,
      "autocommit"        => [] of String,
      "encoding"          => [] of String,
      "trust_input"       => [] of String,
      "search_path"       => [] of String,
    }

    INT_PARAMS  = {"login_port"}
    BOOL_PARAMS = {"autocommit", "trust_input"}
    SSL_MODES   = %w[allow disable prefer require verify-ca verify-full]

    # Real Ansible's kw dict in its own insertion order
    # (exit_json(changed, query, query_list, statusmessage, query_result,
    # query_all_results, rowcount, execution_time_ms)), with `failed: false`
    # backfilled by the controller after the module's kwargs - hence its
    # position. No msg: real exits with none on success.
    # Live-verified against real ansible-core 2.19.11 + community.postgresql
    # 4.2.0.
    SUCCESS_KEY_ORDER = %w[
      changed query query_list statusmessage query_result query_all_results
      rowcount execution_time_ms failed
    ]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      query = @params["query"]?
      unless query
        # Real crashes its statement loop on a nil query (query_list =
        # None) - a failed module either way.
        return PluginResult.new(changed: false, failed: true, msg: "MODULE FAILURE")
      end
      db = @params["login_db"]? || @params["db"]?

      queries = parse_query_list(query)
      positional = parse_list_param("positional_args")
      named = parse_dict_param("named_args")

      autocommit = true?(@params["autocommit"]?)
      check_mode = true?(@params["_ansible_check_mode"]?)
      return PluginResult.new(changed: false, failed: true, msg: "Using autocommit is mutually exclusive with check_mode") if autocommit && check_mode

      search_path = @params["search_path"]?

      login = PluginHelpers::PostgresqlConnection.resolve_login_params(@params)
      uri = PluginHelpers::PostgresqlConnection.build_uri(
        host: login[:host],
        port: login[:port],
        user: login[:user] || "postgres",
        password: login[:password],
        unix_socket: login[:unix_socket],
        dbname: db,
      )

      outcome = begin
        DB.open(uri) do |conn|
          if autocommit
            run_queries(conn, queries, positional, named, search_path)
          else
            final = nil
            conn.transaction do |tx|
              final = run_queries(conn, queries, positional, named, search_path)
              tx.rollback if check_mode
            end
            final.not_nil!
          end
        end
      rescue ex : DB::ConnectionRefused
        return PluginHelpers::DbErrors.pg_connection_failed(ex, @params)
      rescue ex : PQ::PQError
        return PluginHelpers::DbErrors.query_failed(ex, "PostgreSQL")
      end

      res = PluginResult.new(changed: outcome.changed, failed: false,
        failed_flag: true, key_order: SUCCESS_KEY_ORDER)
      res.extra["query"] = JSON::Any.new(outcome.last_sql)
      res.extra["query_list"] = JSON::Any.new(queries.map { |sql| JSON::Any.new(sql) })
      res.extra["statusmessage"] = JSON::Any.new(outcome.statusmessage)
      res.extra["query_result"] = outcome.last_result
      res.extra["query_all_results"] = JSON::Any.new(outcome.all_results)
      res.extra["rowcount"] = JSON::Any.new(outcome.rowcount)
      res.extra["execution_time_ms"] = JSON::Any.new(outcome.execution_times_ms.map { |elapsed| JSON::Any.new(elapsed) })
      res
    end

    # Real AnsibleModule setup order (ArgumentSpecValidator.validate,
    # errors[0] priority): mutually_exclusive -> required (none - query
    # and login_db are both optional in the live spec) -> types in spec
    # declaration order -> choices -> unsupported params LAST.
    private def validate_arguments : PluginResult?
      positional = parse_list_param("positional_args")
      named = parse_dict_param("named_args")
      if positional && named
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: positional_args|named_args")
      end

      SPEC.each_key do |param|
        value = @params[param]?
        next unless value
        if INT_PARAMS.includes?(param) && !value.strip.matches?(/^[+-]?\d+$/)
          return int_type_error(param, value)
        end
        if BOOL_PARAMS.includes?(param) && !bool_convertible?(value)
          return bool_type_error(param, value)
        end
      end

      if ssl_mode = @params["ssl_mode"]?
        unless SSL_MODES.includes?(ssl_mode)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of ssl_mode must be one of: #{SSL_MODES.join(", ")}, got: #{ssl_mode}")
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("postgresql_query", unsupported, SPEC)
      end

      nil
    end

    private def run_queries(
      conn : DB::Database, queries : Array(String),
      positional : Array(JSON::Any)?, named : Hash(String, JSON::Any)?,
      search_path : String?,
    ) : RunOutcome
      run_set_search_path(conn, search_path)

      all_results = [] of JSON::Any
      last_result = JSON::Any.new([] of JSON::Any)
      last_sql = ""
      rowcount = 0i64
      statusmessage = ""
      changed = false
      execution_times_ms = [] of Float64

      queries.each do |sql|
        expanded_sql, binds = resolve_binds(sql, positional, named)
        last_sql = expanded_sql
        started = Time.monotonic
        rows, affected, tag = run_statement(conn, expanded_sql, binds)
        execution_times_ms << (Time.monotonic - started).total_milliseconds
        rowcount += affected
        statusmessage = tag
        # Real Ansible renders a statement that produced no rows as an
        # EMPTY DICT, not an empty list (its own fetch loop leaves
        # query_result == [] and it then replaces that with {}), so both
        # the per-statement entry in query_all_results and the final
        # query_result are {} for DDL - not [].
        rendered = rows.empty? ? JSON::Any.new({} of String => JSON::Any) : JSON::Any.new(rows.map { |row| JSON::Any.new(row) })
        all_results << rendered
        # Real Ansible's query_result is the LAST statement's whole
        # result set (one dict per row) - not just its first row, which
        # silently dropped every row after the first on a multi-row
        # SELECT.
        last_result = rendered
        changed = true if PluginHelpers::PostgresqlQueryHeuristics.changed?(
                            PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(expanded_sql), affected
                          )
      end

      RunOutcome.new(last_sql, last_result, all_results, rowcount, statusmessage, changed, execution_times_ms)
    end

    private def run_set_search_path(conn : DB::Database, search_path : String?) : Nil
      return unless search_path && !search_path.strip.empty?
      schemas = search_path.split(',').map(&.strip.strip('"')).join(", ")
      conn.exec "SET search_path TO #{schemas}"
    end

    # Positional args bind to every statement as-is; named args are
    # expanded per-statement (each statement's own %(name)s set).
    private def resolve_binds(sql : String, positional : Array(JSON::Any)?, named : Hash(String, JSON::Any)?) : {String, Array(JSON::Any)}
      return {sql, positional || [] of JSON::Any} if positional
      if named
        expanded, binds = PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(sql, named)
        return {expanded, binds}
      end
      {sql, [] of JSON::Any}
    end

    # SELECT/SHOW/WITH fetch rows; everything else goes through exec
    # for the affected-row count. The statusmessage is synthesized (see
    # the class comment).
    private def run_statement(conn : DB::Database, sql : String, binds : Array(JSON::Any)) : {Array(Hash(String, JSON::Any)), Int64, String}
      keyword = PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(sql).upcase
      args = binds.map { |value| PluginHelpers::PostgresqlQueryHeuristics.bind_value(value).as(DB::Any) }

      if keyword == "SELECT" || keyword == "SHOW" || keyword == "WITH" || keyword == "TABLE"
        rows = [] of Hash(String, JSON::Any)
        conn.query(sql, args: args) do |result_set|
          columns = result_set.column_names
          result_set.each do
            row = Hash(String, JSON::Any).new
            columns.each_with_index do |column, _index|
              row[column] = to_json_any(result_set.read)
            end
            rows << row
          end
        end
        tag_keyword = keyword == "SHOW" ? "SHOW" : "SELECT"
        return rows, rows.size.to_i64, "#{tag_keyword} #{rows.size}"
      end

      result = conn.exec(sql, args: args)
      affected = result.rows_affected
      {[] of Hash(String, JSON::Any), affected, ddl_command_tag(sql, affected)}
    end

    # PostgreSQL's own command tag for a non-row-returning statement,
    # which psycopg2 surfaces as cursor.statusmessage and the real
    # module reports verbatim. crystal-pg does not surface the raw tag,
    # so it is rebuilt from the statement text:
    #   - INSERT/UPDATE/DELETE carry an affected-row count ("INSERT 0 1",
    #     "UPDATE 1", "DELETE 2"), which is exactly what the real
    #     module's changed: rule parses.
    #   - everything else is "<VERB> <OBJECT>" ("CREATE TABLE",
    #     "DROP SCHEMA", "ALTER VIEW", ...) or the bare verb ("SET",
    #     "GRANT", "RESET"). The object word is the first SQL word after
    #     the verb that names an object kind, skipping the modifiers
    #     PostgreSQL itself drops from the tag ("CREATE TEMP TABLE" ->
    #     "CREATE TABLE", "DROP MATERIALIZED VIEW" -> "DROP MATERIALIZED
    #     VIEW", "CREATE OR REPLACE VIEW" -> "CREATE VIEW").
    # Verified against a real PostgreSQL 17 server for CREATE/DROP/ALTER
    # on TABLE/VIEW/SCHEMA/SEQUENCE/INDEX/EXTENSION/MATERIALIZED VIEW,
    # plus TRUNCATE (tagged "TRUNCATE TABLE"), SET, RESET, GRANT, BEGIN,
    # COMMIT and ANALYZE.
    private def ddl_command_tag(sql : String, affected : Int64) : String
      case (keyword = PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(sql).upcase)
      when "INSERT" then "INSERT 0 #{affected}"
      when "UPDATE", "DELETE" then "#{keyword} #{affected}"
      when "TRUNCATE" then "TRUNCATE TABLE"
      else
        object = object_word_after_verb(sql)
        object ? "#{keyword} #{object}" : keyword
      end
    end

    OBJECT_KIND_WORDS = %w[
      TABLE TABLES VIEW SEQUENCE SCHEMA INDEX DATABASE EXTENSION FUNCTION
      PROCEDURE TYPE DOMAIN ROLE POLICY TRIGGER RULE MATERIALIZED
    ]

    private def object_word_after_verb(sql : String) : String?
      words = sql.scan(/[A-Za-z_][A-Za-z_0-9]*/).map { |match| match[0] }.to_a
      return nil if words.size < 2

      # "CREATE MATERIALIZED VIEW" keeps both modifiers; "CREATE TEMP
      # TABLE" / "CREATE UNLOGGED TABLE" / "CREATE OR REPLACE VIEW" keep
      # none of them - so keep MATERIALIZED, drop the per-session and
      # OR REPLACE noise.
      tail = words[1..]
      modifiers = [] of String
      tail.each do |word|
        up = word.upcase
        break if OBJECT_KIND_WORDS.includes?(up)
        modifiers << up if %w[MATERIALIZED TEMP TEMPORARY UNLOGGED].includes?(up)
        break if up == "OR"
      end
      object = tail.find { |word| OBJECT_KIND_WORDS.includes?(word.upcase) }
      return nil unless object
      "#{modifiers.join(" ")} #{object.upcase}".strip
    end

    # crystal-pg's bare read returns the decoder's native type (Nil,
    # Bool, Int16/Int32/Int64, Float32/Float64, String, Time,
    # Slice(UInt8), PG::Numeric, UUID, JSON::PullParser for json/jsonb,
    # PG::Interval...). JSON only carries null/bool/number/string, so
    # the numeric PG types are kept as native JSON numbers (psycopg2
    # hands real Ansible native Python ints/floats too - stringifying
    # them was a visible type divergence), and everything else that has
    # no JSON representation is rendered as text - matching how the real
    # module's non-convertible types end up stringified in the returned
    # dicts (its convert_to_supported() turns PG numeric/timedelta into
    # float/str, so numeric becomes a native JSON number too).
    private def to_json_any(value) : JSON::Any
      case value
      when Nil              then JSON::Any.new(nil)
      when Bool             then JSON::Any.new(value)
      when Int, Float       then JSON::Any.new(value)
      when JSON::PullParser then JSON::Any.new(value)
      when JSON::Any        then value
      when PG::Numeric      then JSON::Any.new(value.to_f)
      when Time             then JSON::Any.new(value.to_s("%Y-%m-%d %H:%M:%S%:z"))
      when Bytes            then JSON::Any.new(String.new(value))
      else                       JSON::Any.new(value.to_s)
      end
    end

    private def parse_query_list(raw : String) : Array(String)
      parsed = JSON.parse(raw)
      if list = parsed.as_a?
        return list.map(&.as_s)
      end
      [parsed.as_s? ? parsed.as_s : raw]
    rescue JSON::ParseException
      [raw]
    end

    private def parse_list_param(key : String) : Array(JSON::Any)?
      raw = @params[key]?
      return nil unless raw && !raw.strip.empty?
      parsed = JSON.parse(raw)
      parsed.as_a? || [parsed]
    rescue JSON::ParseException
      [JSON::Any.new(raw)]
    end

    private def parse_dict_param(key : String) : Hash(String, JSON::Any)?
      raw = @params[key]?
      return nil unless raw && !raw.strip.empty?
      JSON.parse(raw).as_h
    rescue JSON::ParseException
      raise "invalid #{key}: #{raw}"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::PostgresqlQueryPlugin.new(config)
plugin.run

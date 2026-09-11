#!/usr/bin/env crystal

require "json"
require "pg"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/postgresql_connection"
require "../src/krikri/plugin_helpers/postgresql_query_heuristics"

module Krikri
  # postgresql_query plugin (community.postgresql.postgresql_query) -
  # runs SQL against PostgreSQL over the wire protocol through the same
  # shared PostgresqlConnection helper as the other community.postgresql
  # plugins (crystal-pg standing in for psycopg2). Params:
  # - db (alias login_db): required. Database to connect to.
  # - query: SQL string, or a JSON-encoded list of statements run in
  #   order (the real module's list form).
  # - positional_args: JSON list of $1-style binds; named_args: JSON
  #   dict of %(name)s binds (each statement's placeholders expanded to
  #   $N positions - crystal-pg has no named binding). Mutually
  #   exclusive.
  # - login_host/login_port/login_user/login_password/login_unix_socket
  #   (+ deprecated host/port/login/unix_socket aliases, same as the
  #   other plugins).
  # - autocommit: for statements that can't run in a transaction block
  #   (VACUUM). Mutually exclusive with check_mode.
  # - search_path: SET search_path before the query.
  # - check_mode: the query runs, but inside a transaction that is
  #   rolled back at the end (matching the real module's
  #   execute-then-rollback).
  #
  # Returns: query_result (last statement's rows as column->value
  # dicts), query_all_results (one row-list per statement), query_list,
  # rowcount (total produced/affected rows), query, statusmessage.
  #
  # Divergence, deliberate: statusmessage is synthesized from the
  # statement's leading keyword + affected-row count ("INSERT 0 1" /
  # "SELECT 3" style) - crystal-pg does not surface the server's raw
  # command tag. The real module's own changed: determination only ever
  # reads that tag's keyword and trailing count, and that rule is ported
  # exactly (see PostgresqlQueryHeuristics), so changed: itself matches.
  class PostgresqlQueryPlugin < BasePlugin
    private record RunOutcome,
      last_sql : String,
      last_result : Hash(String, JSON::Any),
      all_results : Array(JSON::Any),
      rowcount : Int64,
      statusmessage : String,
      changed : Bool

    def execute : PluginResult
      query = @params["query"]?
      return missing("query") unless query
      db = @params["db"]? || @params["login_db"]?
      return missing("login_db") unless db

      queries = parse_query_list(query)
      positional = parse_list_param("positional_args")
      named = parse_dict_param("named_args")
      return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: positional_args|named_args") if positional && named

      autocommit = true?(@params["autocommit"]?)
      check_mode = true?(@params["check_mode"]?)
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
        return PluginHelpers::DbErrors.connection_failed(ex, "PostgreSQL")
      rescue ex : PQ::PQError
        return PluginHelpers::DbErrors.query_failed(ex, "PostgreSQL")
      end

      res = PluginResult.new(changed: outcome.changed, failed: false, msg: outcome.statusmessage)
      res.extra["query"] = JSON::Any.new(outcome.last_sql)
      res.extra["query_list"] = JSON::Any.new(queries.map { |q| JSON::Any.new(q) })
      res.extra["query_result"] = JSON::Any.new(outcome.last_result)
      res.extra["query_all_results"] = JSON::Any.new(outcome.all_results)
      res.extra["rowcount"] = JSON::Any.new(outcome.rowcount)
      res.extra["statusmessage"] = JSON::Any.new(outcome.statusmessage)
      res
    end

    private def missing(arg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{arg}")
    end

    private def run_queries(
      conn : DB::Database, queries : Array(String),
      positional : Array(JSON::Any)?, named : Hash(String, JSON::Any)?,
      search_path : String?,
    ) : RunOutcome
      run_set_search_path(conn, search_path)

      all_results = [] of JSON::Any
      last_result = Hash(String, JSON::Any).new
      last_sql = ""
      rowcount = 0i64
      statusmessage = ""
      changed = false

      queries.each do |sql|
        expanded_sql, binds = resolve_binds(sql, positional, named)
        last_sql = expanded_sql
        rows, affected, tag = run_statement(conn, expanded_sql, binds)
        rowcount += affected
        statusmessage = tag
        all_results << JSON::Any.new(rows.map { |row| JSON::Any.new(row) })
        last_result = rows.first? || Hash(String, JSON::Any).new
        changed = true if PluginHelpers::PostgresqlQueryHeuristics.changed?(
          PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(expanded_sql), affected
        )
      end

      RunOutcome.new(last_sql, last_result, all_results, rowcount, statusmessage, changed)
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
        conn.query(sql, args: args) do |rs|
          columns = rs.column_names
          rs.each do
            row = Hash(String, JSON::Any).new
            columns.each_with_index do |column, _index|
              row[column] = to_json_any(rs.read)
            end
            rows << row
          end
        end
        tag_keyword = keyword == "SHOW" ? "SHOW" : "SELECT"
        return rows, rows.size.to_i64, "#{tag_keyword} #{rows.size}"
      end

      result = conn.exec(sql, args: args)
      affected = result.rows_affected
      {[] of Hash(String, JSON::Any), affected, "#{keyword} #{affected}"}
    end

    # crystal-pg's bare read returns the decoder's native type (Nil,
    # Bool, Int64, Float64, String, Time, Slice(UInt8), PG::Numeric...).
    # JSON only carries null/bool/number/string, so everything else is
    # rendered as text - matching how the real module's non-convertible
    # types end up stringified in the returned dicts.
    private def to_json_any(value) : JSON::Any
      case value
      when Nil           then JSON::Any.new(nil)
      when Bool          then JSON::Any.new(value)
      when Int64         then JSON::Any.new(value)
      when Float64       then JSON::Any.new(value)
      when PG::Numeric   then JSON::Any.new(value.to_s)
      when Time          then JSON::Any.new(value.to_s("%Y-%m-%d %H:%M:%S%:z"))
      when Bytes         then JSON::Any.new(String.new(value))
      when JSON::Any     then value
      else                    JSON::Any.new(value.to_s)
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

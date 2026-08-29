#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/mysql_connection"

module CrystalPlay
  # MySQL query plugin - runs arbitrary SQL statement(s). Compatible
  # (for the subset of parameters implemented here) with Ansible's
  # community.mysql.mysql_query module.
  #
  # See plugins/mysql_db.cr's module comment for the shared architecture
  # note (talks to the server directly over MySQL's own wire protocol via
  # a fork of crystal-lang/crystal-mysql).
  #
  # Supported parameters:
  # - query: a single SQL statement string, or a JSON-encoded array of
  #   statement strings (PlaybookParser JSON-encodes an array `query:`
  #   value for this module specifically - the same treatment `assert:`'s
  #   `that:` already gets - rather than comma-joining it, which would be
  #   ambiguous with a statement that legitimately contains a comma, e.g.
  #   dev-sec mysql_hardening's own `DELETE ... WHERE HOST NOT IN
  #   ('localhost', '127.0.0.1', '::1')`). Each statement runs as its own
  #   independent round trip - no real multi-statement (`stmt1; stmt2;`
  #   in one string) support, matching how every real caller in this
  #   codebase already writes it (one statement per list element).
  # - login_host/login_port/login_user/login_password/login_unix_socket
  #
  # Result:
  # - query_result: one array per statement, each holding one Hash per
  #   result row (column name => value, all coerced to string - matches
  #   this codebase's existing `db.query_all(..., as: String)` precedent
  #   in mysql_db.cr rather than trying to preserve every MySQL column
  #   type exactly) - empty array for a statement with no rows (a write,
  #   or a read that matched nothing).
  # - rowcount: one integer per statement - the row count for a read,
  #   rows_affected for a write.
  #
  # changed: for a DML statement (INSERT/UPDATE/DELETE/REPLACE), true only
  # if rows_affected > 0 - matches real community.mysql.mysql_query's own
  # `cursor.rowcount > 0` check (mysql_query.py's DML_QUERY_KEYWORDS loop),
  # not an unconditional true. A DDL statement (CREATE/DROP/ALTER/RENAME/
  # TRUNCATE) or anything else still reports changed unconditionally - the
  # real module's DDL branch does its own already-exists detection that
  # isn't replicated here, so unconditional-true is the safe default for
  # the DDL/unrecognized case. Real bug found benchmarking
  # devsec.hardening.mysql_hardening (round 25 live-reverify): the role's
  # `Ensure that root can only login from localhost` task runs `DELETE
  # FROM mysql.user WHERE ... HOST NOT IN (...)` on every run; on a fresh
  # install this matches 0 rows, and real Ansible correctly reports `ok`
  # (idempotent), but this plugin reported `changed` unconditionally.
  #
  # Not implemented: positional_args:/named_args: (parameterized
  # queries) - no real caller in this codebase uses them yet.
  class MysqlQueryPlugin < BasePlugin
    READ_PREFIXES = {"SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN"}
    DML_KEYWORDS  = {"INSERT", "UPDATE", "DELETE", "REPLACE"}

    def execute : PluginResult
      raw_query = @params["query"]?
      unless raw_query
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: query")
      end

      statements = parse_statements(raw_query)
      check_mode = true?(@params["check_mode"]?)
      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would execute #{statements.size} statement(s) (check mode)")
      end

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
      )

      query_results = [] of JSON::Any
      rowcounts = [] of JSON::Any
      changed = false

      DB.open(uri) do |connection|
        statements.each do |stmt|
          if read_statement?(stmt)
            rows, count = run_read(connection, stmt)
            query_results << rows
            rowcounts << JSON::Any.new(count)
          else
            count = connection.exec(stmt).rows_affected
            query_results << JSON::Any.new([] of JSON::Any)
            rowcounts << JSON::Any.new(count)
            changed = true unless dml_statement?(stmt) && count == 0
          end
        end
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "#{statements.size} statement(s) executed",
        query_result: query_results,
        rowcount: rowcounts
      )
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginResult.new(changed: false, failed: true, msg: "MySQL error: #{ex.message}")
    end

    private def parse_statements(raw : String) : Array(String)
      stripped = raw.strip
      if stripped.starts_with?('[')
        parsed = (Array(String).from_json(stripped) rescue nil)
        return parsed if parsed
      end
      [raw]
    end

    private def read_statement?(stmt : String) : Bool
      upcased = stmt.strip.upcase
      READ_PREFIXES.any? { |prefix| upcased.starts_with?(prefix) }
    end

    private def dml_statement?(stmt : String) : Bool
      upcased = stmt.strip.upcase
      DML_KEYWORDS.any? { |kw| upcased.starts_with?(kw) }
    end

    private def run_read(db : DB::Database, stmt : String) : {JSON::Any, Int64}
      rows = [] of JSON::Any
      db.query(stmt) do |result_set|
        columns = (0...result_set.column_count).map { |i| result_set.column_name(i) }
        result_set.each do
          row = Hash(String, JSON::Any).new
          columns.each do |col|
            value = result_set.read
            row[col] = value.nil? ? JSON::Any.new(nil) : JSON::Any.new(value.to_s)
          end
          rows << JSON::Any.new(row)
        end
      end
      {JSON::Any.new(rows), rows.size.to_i64}
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::MysqlQueryPlugin.new(config)
plugin.run

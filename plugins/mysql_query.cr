#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/mysql_connection"

module Krikri
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
  # - login_db: initial database selected on connect (real module: `db =
  #   module.params['login_db']`; no separate `db` alias). Without it the
  #   connection starts with no database selected, so an unqualified query
  #   fails with "No database selected".
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
  # changed: matches real community.mysql.mysql_query's own keyword
  # scan (mysql_query.py's DML_QUERY_KEYWORDS/DML_QUERY_KEYWORDS loop):
  # each statement's leading characters (lstipped, uppercased, first 8
  # chars - len("TRUNCATE")) are scanned for a SUBSTRING match of a DML
  # keyword (INSERT/UPDATE/DELETE/REPLACE), which only marks changed when
  # that statement's rowcount > 0, or a DDL keyword (CREATE/DROP/ALTER/
  # RENAME/TRUNCATE), which marks changed unconditionally. Any other
  # statement (SELECT/SHOW/FLUSH/...) leaves changed at its default
  # false. A DDL statement whose "already exists" server warning fired
  # (IF NOT EXISTS on PyMySQL < 0.10) is the real module's only
  # changed=False carve-out; PyMySQL 1.x never raises it.
  #
  # query_result row values keep native numbers (real round-trips rows
  # through json.dumps, which preserves ints/floats and stringifies
  # everything else) - stringifying them was a visible type divergence
  # on every SELECT.
  #
  # Result also carries executed_queries (the statements as executed,
  # one per statement - real's cursor._last_executed, identical text
  # when there are no bound placeholders).
  #
  # Check mode: the real module declares no supports_check_mode, so
  # real Ansible skips the task with "remote module (...) does not
  # support check mode" after argument validation - reproduced.
  #
  # Not implemented: positional_args:/named_args: (parameterized
  # queries) - no real caller in this codebase uses them yet.
  class MysqlQueryPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    DML_QUERY_KEYWORDS = {"INSERT", "UPDATE", "DELETE", "REPLACE"}
    DDL_QUERY_KEYWORDS = {"CREATE", "DROP", "ALTER", "RENAME", "TRUNCATE"}
    # len("TRUNCATE") - real slices q.lstrip()[0:max_keyword_len].upper()
    KEYWORD_SCAN_LEN = 8

    # The real module's merged argument_spec (mysql_common_argument_spec
    # + mysql_query's own update) in declaration order.
    SPEC = {
      "login_user"        => [] of String,
      "login_password"    => [] of String,
      "login_host"        => [] of String,
      "login_port"        => [] of String,
      "login_unix_socket" => [] of String,
      "config_file"       => [] of String,
      "connect_timeout"   => [] of String,
      "client_cert"       => ["ssl_cert"],
      "client_key"        => ["ssl_key"],
      "ca_cert"           => ["ssl_ca"],
      "check_hostname"    => [] of String,
      "query"             => [] of String,
      "login_db"          => [] of String,
      "positional_args"   => [] of String,
      "named_args"        => [] of String,
      "single_transaction" => [] of String,
      "session_vars"      => [] of String,
    }

    INT_PARAMS  = {"login_port", "connect_timeout"}
    BOOL_PARAMS = {"single_transaction"}

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      if check_mode
        invoked = @params["_module_name"]? || "community.mysql.mysql_query"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true)
      end

      raw_query = @params["query"]?
      unless raw_query
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: query")
      end

      statements = parse_statements(raw_query)

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
        db: @params["login_db"]?,
      )

      query_results = [] of JSON::Any
      rowcounts = [] of JSON::Any
      executed_queries = [] of JSON::Any
      changed = false

      DB.open(uri) do |connection|
        statements.each do |stmt|
          if read_statement?(stmt)
            rows, count = run_read(connection, stmt)
            query_results << rows
            rowcounts << JSON::Any.new(count)
            changed = dml_or_ddl_changed?(stmt, changed, count)
          else
            count = connection.exec(stmt).rows_affected
            query_results << JSON::Any.new([] of JSON::Any)
            rowcounts << JSON::Any.new(count)
            changed = dml_or_ddl_changed?(stmt, changed, count)
          end
          executed_queries << JSON::Any.new(stmt)
        end
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "#{statements.size} statement(s) executed",
        query_result: query_results,
        rowcount: rowcounts,
        executed_queries: executed_queries
      )
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginHelpers::DbErrors.query_failed(ex, "MySQL")
    end

    private def parse_statements(raw : String) : Array(String)
      stripped = raw.strip
      if stripped.starts_with?('[')
        parsed = (Array(String).from_json(stripped) rescue nil)
        return parsed if parsed
      end
      [raw]
    end

    # Real module's per-statement changed scan: the lstripped, uppercased
    # first KEYWORD_SCAN_LEN characters checked for keyword SUBSTRINGS -
    # DML only counts when that statement's rowcount > 0, DDL always
    # counts.
    private def dml_or_ddl_changed?(stmt : String, changed_so_far : Bool, count : Int64) : Bool
      return changed_so_far if changed_so_far
      prefix = stmt.strip.upcase[0, KEYWORD_SCAN_LEN]
      if DML_QUERY_KEYWORDS.any? { |keyword| prefix.includes?(keyword) }
        return count > 0
      end
      DDL_QUERY_KEYWORDS.any? { |keyword| prefix.includes?(keyword) }
    end

    private def validate_arguments : PluginResult?
      positional = @params["positional_args"]?
      named = @params["named_args"]?
      if positional && named
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: positional_args|named_args")
      end

      unless @params["query"]?
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: query")
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

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.mysql.mysql_query", unsupported, SPEC)
      end

      nil
    end

    READ_PREFIXES = {"SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN"}

    private def read_statement?(stmt : String) : Bool
      upcased = stmt.strip.upcase
      READ_PREFIXES.any? { |prefix| upcased.starts_with?(prefix) }
    end

    # Real round-trips each row through json.dumps (default=str): numbers
    # stay native numbers, None stays null, everything else stringifies.
    private def run_read(db : DB::Database, stmt : String) : {JSON::Any, Int64}
      rows = [] of JSON::Any
      db.query(stmt) do |result_set|
        columns = (0...result_set.column_count).map { |i| result_set.column_name(i) }
        result_set.each do
          row = Hash(String, JSON::Any).new
          columns.each do |col|
            value = result_set.read
            row[col] = case value
                       when Nil
                         JSON::Any.new(nil)
                       when Int32, Int64
                         JSON::Any.new(value.to_i64)
                       when Float32, Float64
                         JSON::Any.new(value.to_f)
                       else
                         JSON::Any.new(value.to_s)
                       end
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

plugin = Krikri::MysqlQueryPlugin.new(config)
plugin.run

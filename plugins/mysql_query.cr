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
  # - login_db: initial database selected on connect (Ansible module: `db =
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
  # Ansible module's DDL branch does its own already-exists detection that
  # isn't replicated here, so unconditional-true is the safe default for
  # the DDL/unrecognized case. Real bug found benchmarking
  # devsec.hardening.mysql_hardening (round 25 live-reverify): the role's
  # `Ensure that root can only login from localhost` task runs `DELETE
  # FROM mysql.user WHERE ... HOST NOT IN (...)` on every run; on a fresh
  # install this matches 0 rows, and Ansible correctly reports `ok`
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
  # (IF NOT EXISTS on PyMySQL < 0.10) is the Ansible module's only
  # changed=False carve-out; PyMySQL 1.x never raises it.
  #
  # query_result row values keep native numbers (real round-trips rows
  # through json.dumps, which preserves ints/floats and stringifies
  # everything else) - stringifying them was a visible type divergence
  # on every SELECT.
  #
  # Result also carries executed_queries (the statements as executed,
  # one per statement - Ansible's cursor._last_executed, identical text
  # when there are no bound placeholders).
  #
  # Check mode: the Ansible module declares no supports_check_mode, so
  # Ansible skips the task with "remote module (...) does not
  # support check mode" after argument validation - reproduced.
  #
  # positional_args:/named_args: are bound client-side like pymysql
  # (see bind_arguments).
  class MysqlQueryPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Live-verified 2.19.11 + community.mysql 5.0.2: the module's own
    # exit_json kwargs, in its own order (no `msg` on success).
    private SUCCESS_KEY_ORDER = %w[changed executed_queries query_result rowcount execution_time_ms failed]

    DML_QUERY_KEYWORDS = {"INSERT", "UPDATE", "DELETE", "REPLACE"}
    DDL_QUERY_KEYWORDS = {"CREATE", "DROP", "ALTER", "RENAME", "TRUNCATE"}
    # len("TRUNCATE") - real slices q.lstrip()[0:max_keyword_len].upper()
    KEYWORD_SCAN_LEN = 8

    # The Ansible module's merged argument_spec (mysql_common_argument_spec
    # + mysql_query's own update) in declaration order.
    SPEC = {
      "login_user"         => [] of String,
      "login_password"     => [] of String,
      "login_host"         => [] of String,
      "login_port"         => [] of String,
      "login_unix_socket"  => [] of String,
      "config_file"        => [] of String,
      "connect_timeout"    => [] of String,
      "client_cert"        => ["ssl_cert"],
      "client_key"         => ["ssl_key"],
      "ca_cert"            => ["ssl_ca"],
      "check_hostname"     => [] of String,
      "query"              => [] of String,
      "login_db"           => [] of String,
      "positional_args"    => [] of String,
      "named_args"         => [] of String,
      "single_transaction" => [] of String,
      "session_vars"       => [] of String,
    }

    INT_PARAMS  = {"login_port", "connect_timeout"}
    BOOL_PARAMS = {"single_transaction"}

    # Everything real runs before it has a statement to parse or bind: the
    # argument-spec checks, the check-mode skip, and mysql_query.py's own
    # query presence/type gates. Returns the query text on success.
    private def preflight_query : String | PluginResult
      if err = validate_arguments
        return err
      end

      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.mysql.mysql_query"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true)
      end

      raw_query = @params["query"]?
      unless raw_query
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: query")
      end

      if err = query_type_error(raw_query)
        return err
      end

      raw_query
    end

    def execute : PluginResult
      raw_query = preflight_query
      return raw_query if raw_query.is_a?(PluginResult)

      statements = parse_statements(raw_query)
      bound = bind_arguments(statements)
      return bound if bound.is_a?(PluginResult)
      statements = bound

      # mysql_query.py fails with mysql_driver_fail_msg when neither PyMySQL
      # nor MySQLdb imports, before the connection attempt.
      if err = PluginHelpers::MysqlConnection.mysql_driver_missing_result(@vars)
        return err
      end

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
        db: @params["login_db"]?,
        tls: PluginHelpers::MysqlConnection.tls_options(@params),
        connect_timeout: @params["connect_timeout"]?,
      )

      query_results = [] of JSON::Any
      rowcounts = [] of JSON::Any
      executed_queries = [] of JSON::Any
      execution_times = [] of JSON::Any
      changed = false
      server_version = ""

      # PyMySQL fails a connect_timeout outside (0, 31536000] from its own
      # __init__ range check, before any socket exists; the shard would
      # otherwise drop such a value and hang for the OS's connect timeout
      # (see MysqlConnection.connect_timeout_out_of_range?).
      if PluginHelpers::MysqlConnection.connect_timeout_out_of_range?(@params)
        return PluginHelpers::MysqlConnection.add_mysqldb_connector_warning(
          PluginHelpers::MysqlConnection.connection_failed_result(@params, @vars,
            detail_override: PluginHelpers::MysqlConnection::CONNECT_TIMEOUT_RANGE_MSG))
      end

      DB.open(uri) do |connection|
        # Upstream's get_server_implementation warns about MariaDB right
        # after the connection, before the first statement runs.
        server_version = connection.query_one("SELECT VERSION()", as: String)
        statements.each do |stmt|
          started = Time.monotonic
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
          # Real times each statement's round trip in milliseconds,
          # rounded to 4 decimal places, and reports the list as
          # `execution_time_ms`.
          execution_times << JSON::Any.new(((Time.monotonic - started).total_seconds * 1000).round(4))
        end
      end

      # Ansible's exit_json passes no `msg` at all on success, and leads
      # with `changed` - live-verified 2.19.11 + community.mysql 5.0.2.
      result = PluginResult.new(
        changed: changed,
        failed: false,
        executed_queries: executed_queries,
        query_result: query_results,
        rowcount: rowcounts,
        execution_time_ms: execution_times,
        failed_flag: true,
        key_order: SUCCESS_KEY_ORDER
      )
      # mysql_query.py's connect failure wrapper (mysql_connect raises =>
      # fail_json) sits downstream of the connector warn inside
      # mysql_connect, so even a refused connection's result carries it.
      PluginHelpers::MysqlConnection.add_mysqldb_connector_warning(result)
      PluginHelpers::MysqlConnection.add_mariadb_warning(result, server_version)
    rescue ex : DB::ConnectionRefused
      # mysql_query.py's own connection-failure wrapper (no option-file
      # existence branch, unlike mysql_db/mysql_variables), with the driver's
      # exception repr as its tail.
      PluginHelpers::MysqlConnection.add_mysqldb_connector_warning(
        PluginHelpers::MysqlConnection.connection_failed_result(@params, @vars,
          connect_timed_out: ex.cause.is_a?(IO::TimeoutError)))
    rescue ex : MySql::Connection::PacketError
      # A statement failing after the connect still carries both warns real
      # recorded before it ran (get_server_implementation's MariaDB notice
      # included), so this failure keeps them too.
      result = PluginHelpers::DbErrors.query_failed(ex, "MySQL")
      PluginHelpers::MysqlConnection.add_mysqldb_connector_warning(result)
      PluginHelpers::MysqlConnection.add_mariadb_warning(result, server_version || "")
    end

    # pymysql's cursor.execute(query, args) interpolates client-side: %s
    # (positional_args) or %(name)s (named_args) become escaped literals
    # and %% a literal percent. Without args the query goes through
    # untouched, so a bare % stays as written.
    private def bind_arguments(statements : Array(String)) : Array(String) | PluginResult
      positional = @params["positional_args"]?
      named = @params["named_args"]?
      return statements unless positional || named

      args = JSON.parse(positional || named || "") rescue nil
      if positional
        list = args.try(&.as_a?)
        return bind_failure("positional_args must be a list") unless list
        statements.map { |stmt| bind_positional(stmt, list) }
      else
        map = args.try(&.as_h?)
        return bind_failure("named_args must be a dict") unless map
        statements.map { |stmt| bind_named(stmt, map) }
      end
    rescue ex : BindError
      bind_failure(ex.message || "")
    end

    private class BindError < Exception
    end

    private def bind_failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    private def bind_positional(stmt : String, list : Array(JSON::Any)) : String
      index = 0
      stmt.gsub(/%(%|s)/) do |_, match|
        next "%" if match[1] == "%"
        value = list[index]? || raise BindError.new("not enough arguments for format string")
        index += 1
        self.class.sql_literal(value)
      end
    end

    private def bind_named(stmt : String, map : Hash(String, JSON::Any)) : String
      stmt.gsub(/%(%|\((\w+)\)s)/) do |_, match|
        next "%" if match[1] == "%"
        value = map[match[2]]? || raise BindError.new("'#{match[2]}'")
        self.class.sql_literal(value)
      end
    end

    SQL_ESCAPES = {"\0" => "\\0", "\n" => "\\n", "\r" => "\\r", "\x1a" => "\\Z"}

    def self.sql_literal(value : JSON::Any) : String
      case raw = value.raw
      when Nil     then "NULL"
      when Bool    then raw ? "1" : "0"
      when Int64   then raw.to_s
      when Float64 then raw.to_s
      when String  then quote_string(raw)
      else              quote_string(value.to_json)
      end
    end

    def self.quote_string(text : String) : String
      escaped = text.gsub(/[\\'\0\n\r\x1a]/) { |found| SQL_ESCAPES[found]? || "\\#{found}" }
      "'#{escaped}'"
    end

    # mysql_query.py's own type gate (its main() checks both shapes before
    # the driver import gate and long before the connection attempt): the
    # whole `query:` must be a string or list, and every list member a
    # string. A native non-string literal (`query: 4`) or a whole-span
    # template that resolved to one must be reported here - stringifying
    # it onto the param wire and sending it to the server instead produced
    # a MySQL syntax error where real ansible fails argument validation
    # (live-verified ansible-core 2.21.6 + ansible.mysql 5.2.0).
    private def query_type_error(raw : String) : PluginResult?
      candidates : Array(JSON::Any)
      if native = non_string_param("query")
        return query_value_type_error(native) unless native.raw.is_a?(Array)
        candidates = native.as_a
      elsif parsed = (Array(String).from_json(raw.strip) rescue nil)
        # PlaybookParser JSON-encodes a literal `query:` list, keeping a
        # non-string member's type on the wire under the member marker.
        candidates = parsed.map do |member|
          Krikri.non_string_member_scalar(member) || JSON::Any.new(member)
        end
      elsif members = non_string_member_list("query")
        candidates = members
      else
        return nil
      end

      candidates.each do |member|
        next if member.raw.is_a?(String)
        return PluginResult.new(changed: false, failed: true,
          msg: "the elements in query list must be strings, passed '#{python_str(member)}' " \
               "<class '#{python_type_name(member)}'>")
      end
      nil
    end

    private def query_value_type_error(native : JSON::Any) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "the query option value must be a string or list, passed <class '#{python_type_name(native)}'>")
    end

    # The Python type() repr real's message embeds.
    private def python_type_name(value : JSON::Any) : String
      case value.raw
      when Nil     then "NoneType"
      when Bool    then "bool"
      when Int64   then "int"
      when Float64 then "float"
      when String  then "str"
      when Array   then "list"
      else              "dict"
      end
    end

    # Python's str(), for the "%s" real's element message prints with.
    private def python_str(value : JSON::Any) : String
      case raw = value.raw
      when Nil    then "None"
      when Bool   then raw ? "True" : "False"
      when String then raw
      else             raw.to_s
      end
    end

    private def parse_statements(raw : String) : Array(String)
      stripped = raw.strip
      if stripped.starts_with?('[')
        parsed = (Array(String).from_json(stripped) rescue nil)
        return parsed if parsed
      end
      [raw]
    end

    # Ansible module's per-statement changed scan: the lstripped, uppercased
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
        if INT_PARAMS.includes?(param) && !int_convertible?(value)
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

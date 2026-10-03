#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/mysql_connection"
require "../src/krikri/plugin_helpers/mysql_info_version"
require "../src/krikri/plugin_helpers/mysql_privileges"
require "../src/krikri/plugin_helpers/sql_quoting"

module Krikri
  # MySQL info plugin - reads server metadata. Compatible (for the
  # filters implemented here) with Ansible's community.mysql.mysql_info
  # module.
  #
  # See plugins/mysql_db.cr's module comment for the shared architecture
  # note (talks to the server directly over MySQL's own wire protocol via
  # a fork of crystal-lang/crystal-mysql).
  #
  # Supported parameters:
  # - filter: comma-separated list (or a YAML list) of the subset names
  #   real's own module accepts - version, databases, settings,
  #   global_status, engines, users, users_info, master_status,
  #   slave_hosts, slave_status - with real's `!name` exclusion form and
  #   its "an include wins over an exclude" rule. Only the keys the
  #   filter keeps are emitted, exactly as real's get_info does.
  # - return_empty_dbs: include databases that hold no tables at all
  #   (real reports them with size/tables 0).
  # - login_host/login_port/login_user/login_password/login_unix_socket
  #
  # Result:
  # - version: {major, minor, release, full, suffix} - parsed exactly the
  #   way real Ansible's mysql_info does it (its __get_global_variables):
  #   `full` is the ENTIRE `SELECT VERSION()` string unmodified;
  #   major/minor are the first two dot components, `release` is the third
  #   dot component up to its first `-`, and `suffix` is that same third
  #   component after the first `-` (empty when there is none). Note the
  #   real module only ever looks inside that third component, so a
  #   version like "10.11.14-MariaDB-0ubuntu0.24.04.1" gets suffix
  #   "MariaDB-0ubuntu0" (the ".24.04.1" tail lands in later dot
  #   components it never reads) - reproduced here for parity, verified
  #   against the installed module, not from memory.
  # - settings: {variable_name => value}, from `SHOW VARIABLES` - every
  #   variable, not filtered to a known subset, since callers (mysql_
  #   hardening's own configure.yml) read arbitrary keys like `datadir`/
  #   `log_error` directly.
  #
  # Not implemented: exclude_fields (db_size/db_table_count are always
  # computed), proxy-privilege-only accounts in users_info, and the
  # mysql.user columns this vendored driver cannot decode at all
  # (authentication_string is a LONGTEXT) - see UNREADABLE_COLUMN_TYPES.
  #
  # Never reports changed (a pure read), matches real Ansible.
  class MysqlInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real's exit_json kwargs in its own order (mysql_info.py's
    # module.exit_json), live-verified against ansible-playbook 2.19.11
    # with community.mysql 5.0.2 on a MySQL 8.4 server.
    private SUCCESS_KEY_ORDER = %w[
      changed server_engine connector_name connector_version
      version databases settings global_status engines
      users users_info master_status slave_hosts slave_status failed
    ]

    # Every subset name real's `filter:` accepts, in the order real's own
    # self.info dict declares (and therefore emits) them.
    private SUBSETS = %w[
      version databases settings global_status engines
      users users_info master_status slave_hosts slave_status
    ]

    # mysql.user column types this vendored driver has no read for (the
    # base "not supported read" raise covers the whole blob family), so
    # the users/users_info queries name their columns explicitly instead
    # of running a SELECT * that would fail the whole task.
    private UNREADABLE_COLUMN_TYPES = {
      "tinytext", "text", "mediumtext", "longtext",
      "tinyblob", "blob", "mediumblob", "longblob", "json",
    }

    # The real module's merged argument_spec (community.mysql's
    # mysql_common_argument_spec + mysql_info's own update) in
    # declaration order - values are the spec's aliases.
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
      "login_db"          => [] of String,
      "filter"            => [] of String,
      "exclude_fields"    => [] of String,
      "return_empty_dbs"  => [] of String,
    }

    INT_PARAMS  = {"login_port", "connect_timeout"}
    BOOL_PARAMS = {"check_hostname", "return_empty_dbs"}

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      filters = parse_filter(@params["filter"]?)
      unknown = filters.reject { |entry| SUBSETS.includes?(entry.lstrip('!')) }

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
      )

      wanted = resolve_filter(filters.reject { |entry| unknown.includes?(entry) })

      engine_name = "MySQL"
      result = PluginResult.new(changed: false, failed: false, msg: "",
        # Real names the PYTHON connector it used (its own get_connector_*
        # helpers), and falls back to "Unknown" when it cannot identify
        # one - which is exactly this engine's case: there is no Python
        # driver here, only krikri's own MySQL wire implementation.
        server_engine: engine_name,
        connector_name: "Unknown",
        connector_version: "Unknown",
        key_order: SUCCESS_KEY_ORDER)

      # Real's module.warn for every filter element that isn't a known
      # subset name (mysql_info.py's get_info): the element is ignored and
      # the warning rides on the result, after `failed`.
      unless unknown.empty?
        result.extra["warnings"] = JSON::Any.new(unknown.map { |entry| JSON::Any.new("filter element: #{entry} is not allowable, ignored") })
      end

      DB.open(uri) do |connection|
        engine_name = implementation_of(connection)
        collect(connection, wanted) do |name, value|
          result.extra[name] = value
        end
      end

      result
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginHelpers::DbErrors.query_failed(ex, "MySQL")
    end

    # Real's get_server_implementation: a server that identifies itself
    # as MariaDB is the only thing it ever calls MariaDB.
    private def implementation_of(db : DB::Database) : String
      rows = rows_as_hashes(db, "SELECT VERSION() AS version")
      first = rows.first?
      version = first ? (first["version"]? || "") : ""
      version.downcase.includes?("mariadb") ? "MariaDB" : "MySQL"
    end

    # Every row of *sql* as a {column => value-as-text} Hash - the shape
    # real's DictCursor gives its own collectors, which then convert each
    # value (see #convert).
    private def rows_as_hashes(db : DB::Database, sql : String) : Array(Hash(String, String))
      rows = [] of Hash(String, String)
      db.query(sql) do |result_set|
        columns = result_set.column_names
        result_set.each do
          row = {} of String => String
          columns.each { |column| row[column] = result_set.read.to_s }
          rows << row
        end
      end
      rows
    end

    # The `filter:` value as real's own list argument spec sees it: a YAML
    # list or a comma-separated string, either way a list of subset names
    # (real's argspec coerces a plain string into one too).
    private def parse_filter(raw : String?) : Array(String)
      (raw || "").split(',').map(&.strip).reject(&.empty?)
    end

    # Real's own filter handling (mysql_info.py's get_info): `!name`
    # entries are exclusions, plain names are inclusions, and any
    # inclusion at all makes the exclusions irrelevant. With no filter
    # every subset is collected, in self.info declaration order.
    private def resolve_filter(filters : Array(String)) : Array(String)
      return SUBSETS.dup if filters.empty?

      includes = filters.reject { |entry| entry.starts_with?("!") }.map(&.lstrip('!')).select { |entry| SUBSETS.includes?(entry) }
      excludes = filters.select(&.starts_with?("!")).map(&.lstrip('!')).select { |entry| SUBSETS.includes?(entry) }

      return SUBSETS.select { |subset| includes.includes?(subset) } if includes.present?
      SUBSETS.reject { |subset| excludes.includes?(subset) }
    end

    # Runs each wanted subset's collector, in SUBSETS order, and hands
    # each result to the block - real builds the dict in that same order,
    # which is what the registered key order shows.
    private def collect(db : DB::Database, wanted : Array(String), &) : Nil
      collectors = {
        "global_status" => ->(connection : DB::Database) { collect_global_status(connection) },
        "databases"     => ->(connection : DB::Database) { collect_databases(connection) },
        "engines"       => ->(connection : DB::Database) { collect_engines(connection) },
        "users"         => ->(connection : DB::Database) { collect_users(connection) },
        "users_info"    => ->(connection : DB::Database) { collect_users_info(connection) },
        "master_status" => ->(connection : DB::Database) { collect_master_status(connection) },
        "slave_hosts"   => ->(connection : DB::Database) { collect_slave_hosts(connection) },
        "slave_status"  => ->(connection : DB::Database) { collect_slave_status(connection) },
      }

      wanted.each do |name|
        # Real collects `settings` whenever `version` is wanted too (its
        # __get_global_variables reads one SHOW GLOBAL VARIABLES for
        # both), but only ever REPORTS the subset the filter kept.
        if name == "version" || name == "settings"
          variables = global_variables(db)
          yield "version", fetch_version(variables) if name == "version"
          yield "settings", JSON::Any.new(variables) if name == "settings"
          next
        end
        next unless collector = collectors[name]?
        yield name, collector.call(db)
      end
    end

    private def collect_global_status(db : DB::Database) : JSON::Any
      rows = {} of String => JSON::Any
      rows_as_hashes(db, "SHOW GLOBAL STATUS").each do |row|
        rows[row["Variable_name"]] = convert(row["Value"]? || "")
      end
      JSON::Any.new(rows)
    end

    private def collect_databases(db : DB::Database) : JSON::Any
      databases = {} of String => JSON::Any
      rows_as_hashes(db, "SELECT table_schema AS name, SUM(data_length + index_length) AS size, COUNT(table_name) AS tables FROM information_schema.TABLES GROUP BY table_schema").each do |row|
        databases[row["name"]] = database_entry(row["size"]? || "", row["tables"]? || "")
      end

      if true?(@params["return_empty_dbs"]?)
        rows_as_hashes(db, "SHOW DATABASES").each do |row|
          databases[row["Database"]] ||= database_entry("", "")
        end
      end

      JSON::Any.new(databases)
    end

    private def database_entry(size : String, tables : String) : JSON::Any
      JSON::Any.new({
        # SUM(data_length + index_length) arrives as a DECIMAL, which real
        # converts through float before its int() pass - so the size lands
        # as a plain int, not a float or a string.
        "size"   => JSON::Any.new(size.to_f.to_i64),
        "tables" => JSON::Any.new(tables.to_i64),
      })
    end

    private def collect_engines(db : DB::Database) : JSON::Any
      engines = {} of String => JSON::Any
      rows_as_hashes(db, "SHOW ENGINES").each do |row|
        engine = row["Engine"]?
        next unless engine
        entry = {} of String => JSON::Any
        row.each do |column, value|
          # The engine name itself is the dict key, not a field (real
          # skips the `Engine` column explicitly), and SHOW ENGINES
          # reports NULL for the columns an engine does not support -
          # real passes those NULLs straight through.
          next if column == "Engine"
          entry[column] = value.empty? ? JSON::Any.new(nil) : JSON::Any.new(value)
        end
        engines[engine] = JSON::Any.new(entry)
      end
      JSON::Any.new(engines)
    end

    # mysql.user's own columns, minus the ones this driver cannot
    # decode (see UNREADABLE_COLUMN_TYPES).
    private def user_rows(db : DB::Database) : Array(Hash(String, String))
      columns = db.query_all(
        "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'mysql' AND TABLE_NAME = 'user' AND DATA_TYPE NOT IN (?)",
        UNREADABLE_COLUMN_TYPES.to_a.join(", "), as: String
      )
      select_columns = (["Host", "User"] + columns).uniq.map { |column| "`#{column}`" }.join(", ")
      rows_as_hashes(db, "SELECT #{select_columns} FROM mysql.user")
    end

    private def collect_users(db : DB::Database) : JSON::Any
      users = {} of String => JSON::Any
      user_rows(db).each do |row|
        host = row["Host"]? || ""
        user = row["User"]? || ""
        attributes = {} of String => JSON::Any
        row.each do |column, value|
          next if column == "Host" || column == "User"
          attributes[column] = convert(value)
        end
        by_host = (users[host]?.try(&.as_h?) || {} of String => JSON::Any)
        by_host[user] = JSON::Any.new(attributes)
        users[host] = JSON::Any.new(by_host)
      end
      JSON::Any.new(users)
    end

    private def collect_users_info(db : DB::Database) : JSON::Any
      entries = [] of JSON::Any
      user_rows(db).each do |row|
        user = row["User"]? || ""
        host = row["Host"]? || ""
        grants = rows_as_hashes(db, "SHOW GRANTS FOR #{PluginHelpers::SqlQuoting.quote_str(user)}@#{PluginHelpers::SqlQuoting.quote_str(host)}")
        # Real accumulates every GRANT line of an account into one
        # privilege list per target (an account with both static and
        # dynamic privileges has two lines for *.*), keeping the order
        # the server printed them in - so a per-target Set that merely
        # overwrote the earlier line (as current_grants does) would
        # report the wrong list.
        privileges = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
        grants.each do |grant_row|
          grant = PluginHelpers::MysqlPrivileges.parse_show_grants_line(grant_row.values.first? || "")
          next unless grant
          privileges[grant.target].concat(grant.privileges.to_a)
        end
        next if privileges.empty?

        strings = privileges.compact_map do |target, privs|
          # Proxy-only grants are skipped by real too, for the same
          # reason (they cannot round-trip through a GRANT statement).
          next if (privs.to_set - {"PROXY", "GRANT"}).empty?
          "#{target}:#{privs.to_a.join(",")}"
        end
        strings.reject!(&.==("*.*:USAGE")) if strings.size > 1
        next if strings.empty?

        entry = {
          "name" => JSON::Any.new(user),
          "host" => JSON::Any.new(host),
          "priv" => JSON::Any.new(strings.join("/")),
        }
        if limits = resource_limits(row)
          entry["resource_limits"] = limits
        end
        entries << JSON::Any.new(entry)
      end
      JSON::Any.new(entries)
    end

    # Real drops a resource limit whose value is 0, and the whole key
    # when nothing is left.
    private def resource_limits(row : Hash(String, String)) : JSON::Any?
      limits = {} of String => JSON::Any
      {"MAX_QUERIES_PER_HOUR"     => "max_questions",
       "MAX_UPDATES_PER_HOUR"     => "max_updates",
       "MAX_CONNECTIONS_PER_HOUR" => "max_connections",
       "MAX_USER_CONNECTIONS"     => "max_user_connections"}.each do |label, column|
        value = row[column]?
        next unless value
        next if value.to_i64 == 0
        limits[label] = JSON::Any.new(value.to_i64)
      end
      limits.empty? ? nil : JSON::Any.new(limits)
    end

    private def collect_master_status(db : DB::Database) : JSON::Any
      status = {} of String => JSON::Any
      rows_as_hashes(db, replication_command(db, "SHOW MASTER STATUS")).each do |row|
        row.each { |column, value| status[column] = convert(value) }
      end
      JSON::Any.new(status)
    end

    private def collect_slave_hosts(db : DB::Database) : JSON::Any
      hosts = {} of String => JSON::Any
      rows_as_hashes(db, replication_command(db, "SHOW SLAVE HOSTS")).each do |row|
        server_id = row["Server_id"]?
        next unless server_id
        entry = {} of String => JSON::Any
        row.each { |column, value| entry[column] = convert(value) unless column == "Server_id" }
        hosts[server_id] = JSON::Any.new(entry)
      end
      JSON::Any.new(hosts)
    end

    private def collect_slave_status(db : DB::Database) : JSON::Any
      status = {} of String => JSON::Any
      rows_as_hashes(db, replication_command(db, "SHOW SLAVE STATUS")).each do |raw_row|
        row = {} of String => JSON::Any
        raw_row.each { |column, value| row[column] = convert(value) }
        # Real nests a replica's status by master host, port and user,
        # because one SHOW SLAVE STATUS row can hold only one of them.
        host = row["Master_Host"]?.try(&.as_s?) || ""
        next if host.empty?
        by_host = status[host]?.try(&.as_h?) || {} of String => JSON::Any
        by_port = by_host[row["Master_Port"]?.to_s]?.try(&.as_h?) || {} of String => JSON::Any
        by_port[row["Master_User"]?.to_s] = JSON::Any.new(row)
        by_host[row["Master_Port"]?.to_s] = JSON::Any.new(by_port)
        status[host] = JSON::Any.new(by_host)
      end
      JSON::Any.new(status)
    end

    # Real's own CommandResolver picks the statement a given server
    # actually understands (MySQL 8.2+ dropped SHOW MASTER STATUS for SHOW
    # BINARY LOG STATUS, 8.0.22+ the REPLICA spellings, MariaDB its own).
    private def replication_command(db : DB::Database, command : String) : String
      mariadb = implementation_of(db) == "MariaDB"
      version = server_version_tuple(db)
      if command == "SHOW MASTER STATUS"
        return "SHOW BINLOG STATUS" if mariadb && version_at_least?(version, [10, 5, 2])
        return "SHOW BINARY LOG STATUS" if !mariadb && version_at_least?(version, [8, 2, 0])
        return "SHOW MASTER STATUS"
      end
      renamed = (!mariadb && version_at_least?(version, [8, 0, 22])) || (mariadb && version_at_least?(version, [10, 5, 1]))
      return command unless renamed
      case command
      when "SHOW SLAVE STATUS" then "SHOW REPLICA STATUS"
      when "SHOW SLAVE HOSTS"  then "SHOW REPLICAS"
      else                          "SHOW REPLICA HOSTS"
      end
    end

    private def server_version_tuple(db : DB::Database) : Array(Int32)
      rows = rows_as_hashes(db, "SELECT VERSION() AS version")
      first = rows.first?
      raw = first ? (first["version"]? || "") : ""
      parts = [] of Int32
      raw.split(/[^0-9]+/).first(3).each { |part| parts << (part.to_i32? || 0) }
      (parts + [0, 0, 0])[0, 3]
    end

    private def version_at_least?(actual : Array(Int32), wanted : Array(Int32)) : Bool
      wanted <= actual[0, wanted.size]
    end

    # Real's __convert: every value arrives from the driver as text and
    # is turned into an int when it looks like one, left a string
    # otherwise (a NULL stays null, which the collector sees as "").
    private def convert(value : String) : JSON::Any
      if value.matches?(/^\d+$/)
        signed = value.to_i64?
        return JSON::Any.new(signed) if signed
        # Above Int64 (MySQL's own counters go up to 18446744073709551615)
        # Crystal's JSON layer cannot carry the value as a number at all,
        # so it is reported as its decimal text rather than crashing the
        # whole read - a documented type divergence from real.
        return JSON::Any.new(value)
      elsif value.matches?(/^-?\d+$/)
        return JSON::Any.new(value.to_i64)
      end
      JSON::Any.new(value)
    end

    private def collect_settings(db : DB::Database) : JSON::Any
      JSON::Any.new(global_variables(db))
    end

    private def global_variables(db : DB::Database) : Hash(String, JSON::Any)
      settings = {} of String => JSON::Any
      rows_as_hashes(db, "SHOW GLOBAL VARIABLES").each do |row|
        settings[row["Variable_name"]] = convert(row["Value"]? || "")
      end
      settings
    end

    private def collect_version(db : DB::Database) : JSON::Any
      fetch_version(db)
    end

    # Real AnsibleModule setup order for this spec (no required /
    # mutually-exclusive / choices constraints): type conversion per
    # param in spec declaration order, then unsupported params last
    # (arg_spec.py's ArgumentSpecValidator appends UnsupportedError
    # after everything else, and the module surfaces errors[0]).
    private def validate_arguments : PluginResult?
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
        return unsupported_params_error("community.mysql.mysql_info", unsupported, SPEC)
      end

      nil
    end

    private def fetch_version(db : DB::Database) : JSON::Any
      JSON::Any.new(PluginHelpers::MysqlInfoVersion.parse(db.query_one("SELECT VERSION()", as: String)))
    end

    # Real parses the version out of the `version` SETTING, not a
    # SELECT VERSION() round trip - same string, one fewer query.
    private def fetch_version(variables : Hash(String, JSON::Any)) : JSON::Any
      JSON::Any.new(PluginHelpers::MysqlInfoVersion.parse(variables["version"]?.try(&.as_s) || ""))
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::MysqlInfoPlugin.new(config)
plugin.run

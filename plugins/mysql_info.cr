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
  #   Ansible's own module accepts - version, databases, settings,
  #   global_status, engines, users, users_info, master_status,
  #   slave_hosts, slave_status - with Ansible's `!name` exclusion form and
  #   its "an include wins over an exclude" rule. Only the keys the
  #   filter keeps are emitted, exactly as Ansible's get_info does.
  # - exclude_fields: a list (or comma-separated string) of per-database
  #   fields to skip - db_size, db_table_count. Anything else is
  #   silently ignored, exactly as Ansible's own docs promise; an excluded
  #   field is dropped from the `databases` dict AND from the query that
  #   would have produced it.
  # - return_empty_dbs: include databases that hold no tables at all
  #   (Ansible reports them with size/tables 0).
  # - login_host/login_port/login_user/login_password/login_unix_socket
  #
  # Result:
  # - version: {major, minor, release, full, suffix} - parsed exactly the
  #   way Ansible's mysql_info does it (its __get_global_variables):
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
  # Not implemented: proxy-privilege-only accounts in users_info, and the
  # remaining mysql.user columns this vendored driver cannot decode at all
  # (the blob family) - see UNREADABLE_COLUMN_TYPES. authentication_string
  # (a LONGTEXT) is read too, via a server-side CAST to a type the driver
  # does decode.
  #
  # Never reports changed (a pure read), matches Ansible.
  class MysqlInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Ansible's exit_json kwargs in its own order (mysql_info.py's
    # module.exit_json), live-verified against ansible-playbook 2.19.11
    # with community.mysql 5.0.2 on a MySQL 8.4 server.
    private SUCCESS_KEY_ORDER = %w[
      changed server_engine connector_name connector_version
      version databases settings global_status engines
      users users_info master_status slave_hosts slave_status failed
    ]

    # Every subset name Ansible's `filter:` accepts, in the order Ansible's own
    # self.info dict declares (and therefore emits) them.
    private SUBSETS = %w[
      version databases settings global_status engines
      users users_info master_status slave_hosts slave_status
    ]

    # mysql.user column types whose wire representation this vendored
    # driver cannot always read raw (the base "not supported read" raise
    # covers the blob family and JSON on every server, ENUM on MySQL 8's
    # binary protocol, and LONGTEXT on MariaDB): each is selected through
    # LEFT(col, 8192), which the server returns as a plain VARCHAR
    # (VarString) on both engines. (8192, not 65535: MySQL reports a
    # string-function result longer than a TEXT field's byte capacity as
    # LONGTEXT on the wire again, which is exactly the type the wrap is
    # escaping.) Every wrapped type is part of Ansible's
    # SELECT * FROM mysql.user output, so wrapping - not dropping - is
    # what matches real; the wrapped values (password hashes, enum Y/N
    # flags, user attributes JSON) are far under the bound in practice,
    # and a value that would be truncated has no MySQL-side equivalent
    # this driver could read anyway.
    private UNREADABLE_COLUMN_TYPES = {
      "tinytext", "text", "mediumtext", "longtext",
      "tinyblob", "blob", "mediumblob", "longblob", "json",
      "enum", "set",
    }

    # The Ansible module's merged argument_spec (community.mysql's
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
      excluded_fields = parse_filter(@params["exclude_fields"]?)

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
        # Real names the PYTHON connector it actually used (its own
        # get_connector_* helpers): pymysql and pymysql.__version__. This
        # engine talks to the server with its own MySQL wire implementation,
        # but the registered result's connector identity is what callers
        # see, so it mirrors Ansible's driver identity instead of "Unknown" -
        # connector_version carries a pymysql 1.1.x version string.
        server_engine: engine_name,
        connector_name: "pymysql",
        connector_version: "1.1.1",
        key_order: SUCCESS_KEY_ORDER)

      # Ansible's module.warn for every filter element that isn't a known
      # subset name (mysql_info.py's get_info): the element is ignored and
      # the warning rides on the result, after `failed`.
      unless unknown.empty?
        result.extra["warnings"] = JSON::Any.new(unknown.map { |entry| JSON::Any.new("filter element: #{entry} is not allowable, ignored") })
      end

      DB.open(uri) do |connection|
        engine_name = implementation_of(connection)
        collect(connection, wanted, excluded_fields) do |name, value|
          result.extra[name] = value
        end
      end

      result
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginHelpers::DbErrors.query_failed(ex, "MySQL")
    end

    # Ansible's get_server_implementation: a server that identifies itself
    # as MariaDB is the only thing it ever calls MariaDB.
    private def implementation_of(db : DB::Database) : String
      rows = rows_as_hashes(db, "SELECT VERSION() AS version")
      first = rows.first?
      version = first ? (first["version"]? || "") : ""
      version.downcase.includes?("mariadb") ? "MariaDB" : "MySQL"
    end

    # Every row of *sql* as a {column => value-as-text} Hash - the shape
    # Ansible's DictCursor gives its own collectors, which then convert each
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

    # The `filter:` value as Ansible's own list argument spec sees it: a YAML
    # list or a comma-separated string, either way a list of subset names
    # (Ansible's argspec coerces a plain string into one too).
    private def parse_filter(raw : String?) : Array(String)
      text = (raw || "").strip
      # A list that reaches the plugin through a variable or templated
      # args (`filter: "{{ flt }}"`) arrives as JSON array text, a literal
      # YAML list as the comma-joined form.
      if text.starts_with?('[')
        begin
          return Array(String).from_json(text).map(&.strip).reject(&.empty?)
        rescue JSON::ParseException
        end
      end
      text.split(',').map(&.strip).reject(&.empty?)
    end

    # Ansible's own filter handling (mysql_info.py's get_info): `!name`
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
    private def collect(db : DB::Database, wanted : Array(String), excluded_fields : Array(String), &) : Nil
      collectors = {
        "global_status" => ->(connection : DB::Database) { collect_global_status(connection) },
        "databases"     => ->(connection : DB::Database) { collect_databases(connection, excluded_fields) },
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

    # Ansible's `exclude_fields:` (mysql_info.py's __get_databases): it drops
    # the named per-database fields from the emitted dict AND from the
    # query itself, so an excluded field costs nothing to collect. Only
    # `db_size` and `db_table_count` are supported; anything else is
    # silently ignored (live-verified: `exclude_fields: bogus_field`
    # emits no warning and returns the full dict). `size` is emitted
    # first, then `tables`, exactly as Ansible's create_db_info builds it -
    # and a database whose every field is excluded gets an empty dict.
    private def collect_databases(db : DB::Database, excluded_fields : Array(String)) : JSON::Any
      databases = {} of String => JSON::Any
      want_size = !excluded_fields.includes?("db_size")
      want_tables = !excluded_fields.includes?("db_table_count")

      columns = ["table_schema AS name"]
      columns << "SUM(data_length + index_length) AS size" if want_size
      columns << "COUNT(table_name) AS tables" if want_tables
      sql = "SELECT #{columns.join(", ")} FROM information_schema.TABLES GROUP BY table_schema"

      rows_as_hashes(db, sql).each do |row|
        databases[row["name"]] = database_entry(row["size"]? || "", row["tables"]? || "", want_size, want_tables)
      end

      if true?(@params["return_empty_dbs"]?)
        rows_as_hashes(db, "SHOW DATABASES").each do |row|
          databases[row["Database"]] ||= database_entry("", "", want_size, want_tables)
        end
      end

      JSON::Any.new(databases)
    end

    private def database_entry(size : String, tables : String, want_size : Bool = true, want_tables : Bool = true) : JSON::Any
      entry = {} of String => JSON::Any
      # SUM(data_length + index_length) arrives as a DECIMAL, which real
      # converts through float before its int() pass - so the size lands
      # as a plain int, not a float or a string. A database the
      # grouped query never returned (return_empty_dbs only) has no
      # aggregate at all, which Ansible reads as 0.
      entry["size"] = JSON::Any.new(size.empty? ? 0_i64 : size.to_f.to_i64) if want_size
      entry["tables"] = JSON::Any.new(tables.empty? ? 0_i64 : tables.to_i64) if want_tables
      JSON::Any.new(entry)
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
          # Ansible passes those NULLs straight through.
          next if column == "Engine"
          entry[column] = value.empty? ? JSON::Any.new(nil) : JSON::Any.new(value)
        end
        engines[engine] = JSON::Any.new(entry)
      end
      JSON::Any.new(engines)
    end

    # mysql.user's own columns, every one of them Ansible's
    # SELECT * FROM mysql.user reports (see UNREADABLE_COLUMN_TYPES for
    # the LEFT() wrapping).
    private def user_rows(db : DB::Database) : Array(Hash(String, String))
      # information_schema.COLUMNS's own VARCHAR columns come over the
      # wire as MYSQL_TYPE_VARCHAR, which this driver cannot read raw -
      # LEFT() rewrites both as readable VAR_STRINGs (same trick as the
      # wrapped mysql.user columns below).
      column_types = db.query_all(
        "SELECT COLUMN_NAME, LEFT(DATA_TYPE, 64) AS DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'mysql' AND TABLE_NAME = 'user'",
        as: {String, String}
      )

      # Ansible's users collector runs SELECT * FROM mysql.user, whose first
      # two columns are Host and User; keep that leading order and
      # information_schema's own order for the rest.
      select_columns = ["`Host`", "`User`"]
      column_types.each do |column, data_type|
        next if column == "Host" || column == "User"
        if UNREADABLE_COLUMN_TYPES.includes?(data_type)
          select_columns << "LEFT(`#{column}`, 8192) AS `#{column}`"
        else
          select_columns << "`#{column}`"
        end
      end
      rows_as_hashes(db, "SELECT #{select_columns.join(", ")} FROM mysql.user")
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

    # Ansible's own CommandResolver picks the statement a given server
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

    # Ansible's __convert: every value arrives from the driver as text and
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

    # AnsibleModule setup order for this spec (no required /
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

    # Ansible parses the version out of the `version` SETTING, not a
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

#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/mysql_connection"
require "../src/krikri/plugin_helpers/mysql_info_version"

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
  # - filter: comma-separated list (or a single value) of "version"/
  #   "settings". Any other filter name real Ansible supports (users,
  #   databases, engines, master_status, ...) is accepted but produces
  #   no key in the result - dev-sec's own mysql_hardening role, the
  #   only real-world caller in this codebase, only ever asks for these
  #   two.
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
  # Never reports changed (a pure read), matches real Ansible.
  class MysqlInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's merged argument_spec (community.mysql's
    # mysql_common_argument_spec + mysql_info's own update) in
    # declaration order - values are the spec's aliases.
    SPEC = {
      "login_user"       => [] of String,
      "login_password"   => [] of String,
      "login_host"       => [] of String,
      "login_port"       => [] of String,
      "login_unix_socket" => [] of String,
      "config_file"      => [] of String,
      "connect_timeout"  => [] of String,
      "client_cert"      => ["ssl_cert"],
      "client_key"       => ["ssl_key"],
      "ca_cert"          => ["ssl_ca"],
      "check_hostname"   => [] of String,
      "login_db"         => [] of String,
      "filter"           => [] of String,
      "exclude_fields"   => [] of String,
      "return_empty_dbs" => [] of String,
    }

    INT_PARAMS = {"login_port", "connect_timeout"}
    BOOL_PARAMS = {"check_hostname", "return_empty_dbs"}

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      filters = (@params["filter"]? || "").split(',').map(&.strip).reject(&.empty?).to_set

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
      )

      result = PluginResult.new(changed: false, failed: false, msg: "")

      DB.open(uri) do |connection|
        result.extra["version"] = fetch_version(connection) if filters.empty? || filters.includes?("version")
        result.extra["settings"] = fetch_settings(connection) if filters.empty? || filters.includes?("settings")
      end

      result
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginHelpers::DbErrors.query_failed(ex, "MySQL")
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

    private def fetch_settings(db : DB::Database) : JSON::Any
      settings = Hash(String, JSON::Any).new
      db.query("SHOW VARIABLES") do |result_set|
        result_set.each do
          name = result_set.read.to_s
          value = result_set.read
          settings[name] = JSON::Any.new(value.to_s)
        end
      end
      JSON::Any.new(settings)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::MysqlInfoPlugin.new(config)
plugin.run

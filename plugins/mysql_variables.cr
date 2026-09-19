#!/usr/bin/env crystal
# community.mysql.mysql_variables - queries / sets MySQL or MariaDB
# global server variables over the MySQL wire protocol (same shared
# connection path as the other community.mysql plugins - see
# plugins/mysql_db.cr's module comment). Ported from community.mysql's
# mysql_variables module (round 310090: Oefenweb.percona_server reads
# `datadir` and sets `innodb_fast_shutdown` through it; previously
# unavailable -> rc=4 "unavailable modules").
#
# Semantics matching the real module:
# - variable is required=True in the real argument_spec, so a missing
#   variable fails at module setup with "missing required arguments:
#   variable" (the module body's own "Cannot run without variable to
#   operate with" check is unreachable dead code in the real module -
#   not reproduced); unknown variable ->
#   "Variable not available \"X\"".
# - no value -> pure read: exits with the variable's current value as
#   msg, changed=false.
# - value given -> typedvalue conversion (numeric strings become
#   numbers), 0/1/on/off normalized to ON/OFF when the server currently
#   reports ON/OFF, compared against the current value, and only a
#   difference issues SET GLOBAL (mode: global/persist/persist_only).
# - returns queries=[executed SET ...] on change, msg
#   "Variable change succeeded prev_value=X".
# - the real module declares no supports_check_mode, so real Ansible
#   skips the task with "remote module (...) does not support check
#   mode" after argument validation - reproduced.
require "json"
require "mysql"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/mysql_connection"
require "../src/krikri/plugin_helpers/mysql_variables"

module Krikri
  class MysqlVariablesPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's merged argument_spec (mysql_common_argument_spec
    # + mysql_variables' own update) in declaration order.
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
      "variable"          => [] of String,
      "value"             => [] of String,
      "mode"              => [] of String,
    }

    INT_PARAMS  = {"login_port", "connect_timeout"}
    BOOL_PARAMS = {"check_hostname"}

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      if check_mode
        invoked = @params["_module_name"]? || "community.mysql.mysql_variables"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true)
      end

      variable = @params["variable"]

      unless PluginHelpers::MysqlVariables.valid_name?(variable)
        return PluginResult.new(changed: false, failed: true,
          msg: "invalid variable name \"#{variable}\"")
      end

      value = @params["value"]?
      mode = @params["mode"]? || "global"

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
      )

      DB.open(uri) do |connection|
        current = read_variable(connection, variable)
        return PluginResult.new(changed: false, failed: true,
          msg: "Variable not available \"#{variable}\"") unless current

        return PluginResult.new(changed: false, failed: false, msg: current) unless value

        typed_wanted = PluginHelpers::MysqlVariables.typed_value(value)
        typed_current = PluginHelpers::MysqlVariables.typed_value(current)
        if typed_current.to_s == "ON" || typed_current.to_s == "OFF"
          typed_wanted = PluginHelpers::MysqlVariables.convert_bool(typed_wanted)
        end

        if PluginHelpers::MysqlVariables.values_equal?(typed_wanted, typed_current)
          return PluginResult.new(changed: false, failed: false,
            msg: "Variable is already set to requested value.")
        end

        statement = PluginHelpers::MysqlVariables.set_statement(variable, typed_wanted, mode)
        connection.exec(statement)
        PluginResult.new(changed: true, failed: false,
          msg: "Variable change succeeded prev_value=#{typed_current}",
          queries: [statement])
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginHelpers::DbErrors.query_failed(ex, "MySQL")
    end

    # Real AnsibleModule setup order for this spec (no mutually-exclusive
    # constraints): required args, then the spec's types in declaration
    # order, then the mode choices (all arg_spec.py errors, of which the
    # module surfaces errors[0] in that collection order), then
    # unsupported params LAST (UnsupportedError is appended after
    # everything else by ArgumentSpecValidator.validate). The
    # variable-name regex check is the module BODY's first real check
    # and only runs once setup passed.
    private def validate_arguments : PluginResult?
      unless @params["variable"]?
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: variable")
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

      if mode = @params["mode"]?
        unless ["global", "persist", "persist_only"].includes?(mode)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of mode must be one of: global, persist, persist_only, got: #{mode}")
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.mysql.mysql_variables", unsupported, SPEC)
      end

      nil
    end

    private def read_variable(connection : DB::Database, variable : String) : String?
      # SHOW VARIABLES returns two columns (Variable_name, Value) - the
      # value is the SECOND one. Reading column 0 with `as: String` echoed
      # the variable's own name back as its value (ad-hoc CLI sweep vs real
      # ansible, 2026-09-13: msg was "max_connections" instead of "151").
      value = connection.query_one?("SHOW VARIABLES WHERE Variable_name = ?", variable) do |row|
        row.read(String)
        row.read(String?)
      end
      value.is_a?(String) ? value : nil
    rescue
      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::MysqlVariablesPlugin.new(config)
plugin.run

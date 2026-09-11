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
# - variable required and validated against ^[0-9A-Za-z_.]+$
#   ("invalid variable name \"X\""); unknown variable ->
#   "Variable not available \"X\"".
# - no value -> pure read: exits with the variable's current value as
#   msg, changed=false.
# - value given -> typedvalue conversion (numeric strings become
#   numbers), 0/1/on/off normalized to ON/OFF when the server currently
#   reports ON/OFF, compared against the current value, and only a
#   difference issues SET GLOBAL (mode: global/persist/persist_only).
# - returns queries=[executed SET ...] on change, msg
#   "Variable change succeeded prev_value=X".
require "json"
require "mysql"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/mysql_connection"
require "../src/krikri/plugin_helpers/mysql_variables"

module Krikri
  class MysqlVariablesPlugin < BasePlugin
    def execute : PluginResult
      variable = @params["variable"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "Cannot run without variable to operate with") unless variable

      unless PluginHelpers::MysqlVariables.valid_name?(variable)
        return PluginResult.new(changed: false, failed: true,
          msg: "invalid variable name \"#{variable}\"")
      end

      value = @params["value"]?
      mode = @params["mode"]? || "global"
      unless ["global", "persist", "persist_only"].includes?(mode)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of mode must be one of: global, persist, persist_only, got #{mode}")
      end

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

    private def read_variable(connection : DB::Database, variable : String) : String?
      connection.query_one?(
        "SHOW VARIABLES WHERE Variable_name = ?",
        variable,
        as: String
      )
    rescue
      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::MysqlVariablesPlugin.new(config)
plugin.run

#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/mysql_connection"

module CrystalPlay
  # MySQL database plugin - creates/removes a database.
  # Compatible with Ansible's community.mysql.mysql_db module.
  #
  # Talks to the server directly over MySQL's own wire protocol (real
  # Ansible's own community.mysql collection does the same, via PyMySQL)
  # using a fork of the official crystal-lang/crystal-mysql driver - see
  # https://github.com/weirdbricks/crystal-mysql for the caching_sha2_password
  # (MySQL 8+) and SSL fixes this plugin depends on; upstream, as of
  # 0.17.0, can't connect to a stock MySQL 8+ server at all.
  #
  # Supported parameters:
  # - name: database name (required)
  # - state: present (default) / absent
  # - encoding: charset name for CREATE DATABASE (e.g. "utf8mb4")
  # - collation: collation name for CREATE DATABASE
  # - login_host (default "localhost"), login_port (default 3306),
  #   login_user, login_password, login_unix_socket (takes precedence
  #   over login_host/login_port when given)
  # - check_mode
  #
  # Not implemented: state: dump/import (real Ansible's mysqldump-based
  # backup/restore), config_file: (~/.my.cnf credential lookup),
  # encoding:/collation: validation against the server's actually
  # supported charsets - an invalid value is passed straight through and
  # surfaces as whatever error the server itself returns.
  class MysqlDbPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
      )

      DB.open(uri) do |db|
        exists = db.query_all("SHOW DATABASES", as: String).includes?(name)

        case state
        when "present"
          ensure_present(db, name, exists, check_mode)
        when "absent"
          ensure_absent(db, name, exists, check_mode)
        else
          PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
        end
      end
    rescue ex : DB::ConnectionRefused
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the MySQL server: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginResult.new(changed: false, failed: true, msg: "MySQL error: #{ex.message}")
    end

    private def ensure_present(db : DB::Database, name : String, exists : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Database #{name} already exists") if exists
      return PluginResult.new(changed: true, failed: false, msg: "Database #{name} would be created") if check_mode

      encoding = @params["encoding"]?
      collation = @params["collation"]?
      unless charset_safe?(encoding) && charset_safe?(collation)
        return PluginResult.new(changed: false, failed: true, msg: "encoding/collation may only contain letters, digits, and underscores")
      end

      clause = String.build do |s|
        s << " CHARACTER SET " << encoding if encoding
        s << " COLLATE " << collation if collation
      end

      db.exec "CREATE DATABASE #{quote_ident(name)}#{clause}"
      PluginResult.new(changed: true, failed: false, msg: "Created database #{name}")
    end

    private def ensure_absent(db : DB::Database, name : String, exists : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Database already absent") unless exists
      return PluginResult.new(changed: true, failed: false, msg: "Database #{name} would be removed") if check_mode

      db.exec "DROP DATABASE #{quote_ident(name)}"
      PluginResult.new(changed: true, failed: false, msg: "Removed database #{name}")
    end

    # encoding:/collation: are bare SQL identifiers (not values), so they
    # can't go through a bind parameter - restricting them to a safe
    # charset avoids needing to interpolate arbitrary user input into the
    # query at all.
    private def charset_safe?(value : String?) : Bool
      value.nil? || value.matches?(/\A[A-Za-z0-9_]+\z/)
    end

    private def quote_ident(s : String) : String
      "`" + s.gsub("`", "``") + "`"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::MysqlDbPlugin.new(config)
plugin.run

#!/usr/bin/env crystal

require "json"
require "pg"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/postgresql_connection"

module CrystalPlay
  # PostgreSQL database plugin - creates/removes a database.
  # Compatible with Ansible's community.postgresql.postgresql_db module.
  #
  # Talks to the server directly over PostgreSQL's own wire protocol
  # (real Ansible's own community.postgresql collection does the same,
  # via psycopg2) using will/crystal-pg - unlike the MySQL driver this
  # project also depends on, no fork was needed: verified against real
  # PostgreSQL 17 (SCRAM-SHA-256 auth, the modern default, and SSL both
  # worked against a real server on the first try).
  #
  # Supported parameters:
  # - name: database name (required)
  # - state: present (default) / absent
  # - owner: role to set as the database's owner
  # - encoding: charset name for CREATE DATABASE (e.g. "UTF8")
  # - maintenance_db: database to connect to in order to run CREATE/DROP
  #   DATABASE against `name` (PostgreSQL can't drop/create the database
  #   a connection is currently using) - default "postgres", matching
  #   real Ansible's own default
  # - login_host (default "localhost" - a simplification versus real
  #   Ansible, which defaults to "" and lets the driver fall back to a
  #   local unix socket; this codebase's other plugins default to a
  #   plain TCP localhost connection instead, so this matches that),
  #   login_port (default 5432), login_user (default "postgres",
  #   matching real Ansible), login_password, login_unix_socket (takes
  #   precedence over login_host/login_port when given)
  # - check_mode
  #
  # Not implemented: state: dump/import (real Ansible's pg_dump-based
  # backup/restore), collation:/lc_collate:/lc_ctype:/template:/tablespace:,
  # force: (terminate other connections before DROP DATABASE),
  # session_role:, trust_input: (SQL-injection guard on option values -
  # this plugin always quotes identifiers itself instead).
  class PostgresqlDbPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      uri = PluginHelpers::PostgresqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]? || "postgres",
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        dbname: @params["maintenance_db"]? || "postgres",
      )

      DB.open(uri) do |db|
        exists = db.query_all("SELECT datname FROM pg_database", as: String).includes?(name)

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
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the PostgreSQL server: #{ex.message}")
    rescue ex : PQ::PQError
      PluginResult.new(changed: false, failed: true, msg: "PostgreSQL error: #{ex.message}")
    end

    private def ensure_present(db : DB::Database, name : String, exists : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Database #{name} already exists") if exists
      return PluginResult.new(changed: true, failed: false, msg: "Database #{name} would be created") if check_mode

      owner = @params["owner"]?
      encoding = @params["encoding"]?
      unless identifier_safe?(owner) && identifier_safe?(encoding)
        return PluginResult.new(changed: false, failed: true, msg: "owner/encoding may only contain letters, digits, and underscores")
      end

      clause = String.build do |s|
        s << " OWNER " << quote_ident(owner.not_nil!) if owner
        s << " ENCODING " << quote_str(encoding.not_nil!) if encoding
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

    # owner:/encoding: can't go through a bind parameter (they're
    # identifiers/keywords, not values), so restrict them to safe
    # characters rather than interpolating arbitrary input into the query.
    private def identifier_safe?(value : String?) : Bool
      value.nil? || value.matches?(/\A[A-Za-z0-9_]+\z/)
    end

    private def quote_ident(s : String) : String
      "\"" + s.gsub("\"", "\"\"") + "\""
    end

    private def quote_str(s : String) : String
      "'" + s.gsub("'", "''") + "'"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::PostgresqlDbPlugin.new(config)
plugin.run

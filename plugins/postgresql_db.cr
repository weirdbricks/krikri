#!/usr/bin/env crystal

require "json"
require "pg"
require "compress/gzip"
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
  # - state: dump / restore (real Ansible's own keyword is `restore`,
  #   *not* `import` like `mysql_db`'s equivalent - verified via
  #   `ansible-doc`, not assumed to match its MySQL counterpart): shells
  #   out to `pg_dump`/`psql`, since dump/restore need the actual client
  #   binaries - there's no wire-protocol equivalent of "give me a full
  #   logical SQL dump." `target:` is required for both. Only the plain
  #   `.sql` format is supported, natively `.gz`-compressed via Crystal's
  #   own `Compress::Gzip` rather than shelling to `gzip` (matching
  #   `mysql_db.cr`'s own reasoning) - real Ansible's `.tar`/`.pgc`/
  #   `.dir` formats (handled by `pg_restore` instead of plain `psql`) are
  #   a documented scope cut, see below. Password passed via a `PGPASSWORD=`
  #   environment-variable prefix in the shell command (matches real
  #   Ansible - psql/pg_dump don't take a password CLI flag at all).
  #   Command shape (`pg_dump dbname --host=H --port=P --username=U` /
  #   `psql --dbname=dbname --host=H --port=P --username=U
  #   --file=target`), `restore:`'s `msg:` being `psql`'s actual output
  #   (not empty, unlike `dump:`'s), and the always-`changed: true`-on-
  #   success behavior (not idempotency-checked at all, unlike
  #   present/absent above) all verified against a real `ansible-playbook`
  #   run with `community.postgresql.postgresql_db` against a real
  #   PostgreSQL 17 server, not assumed from the docs.
  # - check_mode
  #
  # Not implemented: `.tar`/`.pgc`/`.dir` formats (`pg_restore`-based,
  # see above) and `.bz2`/`.xz` compression for dump/restore (only plain
  # `.sql` and `.gz`), `collation:`/`lc_collate:`/`lc_ctype:`/`template:`/
  # `tablespace:`, `force:` (terminate other connections before DROP
  # DATABASE), `session_role:`, `trust_input:` (SQL-injection guard on
  # option values - this plugin always quotes identifiers itself instead).
  class PostgresqlDbPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      if state == "dump" || state == "restore"
        return run_dump_or_restore(state, name)
      end

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

    private def run_dump_or_restore(state : String, name : String) : PluginResult
      target = @params["target"]?
      return PluginResult.new(changed: false, failed: true, msg: "target is required when state is dump or restore") unless target

      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "Would #{state} database #{name} #{state == "dump" ? "to" : "from"} #{target} (check mode)")
      end

      state == "dump" ? run_dump(name, target) : run_restore(name, target)
    end

    private def run_dump(name : String, target : String) : PluginResult
      cmd = "#{pgpassword_prefix}pg_dump #{quote(name)} #{login_flags}"
      result = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true, msg: result[:stderr], rc: result[:exit_code]) unless result[:exit_code] == 0

      write_target(target, result[:stdout])
      PluginResult.new(changed: true, failed: false, msg: "", rc: result[:exit_code])
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to write dump to #{target}: #{ex.message}")
    end

    private def run_restore(name : String, target : String) : PluginResult
      return PluginResult.new(changed: false, failed: true, msg: "target #{target} does not exist") unless remote_file_exists?(target)

      sql_path = read_target_as_sql_file(target)
      cmd = "#{pgpassword_prefix}psql --dbname=#{quote(name)} #{login_flags} --file=#{quote(sql_path)}"
      result = remote_exec(cmd)
      File.delete?(sql_path) if sql_path != target

      return PluginResult.new(changed: false, failed: true, msg: result[:stderr], rc: result[:exit_code]) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: result[:stdout], rc: result[:exit_code])
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to restore #{target}: #{ex.message}")
    end

    # psql/pg_dump take no password CLI flag at all - real Ansible passes
    # it via the PGPASSWORD environment variable too.
    private def pgpassword_prefix : String
      password = @params["login_password"]?
      password ? "PGPASSWORD=#{quote(password)} " : ""
    end

    private def login_flags : String
      String.build do |flags|
        flags << "--host=" << quote(@params["login_host"]? || "localhost") << " "
        flags << "--port=" << (@params["login_port"]? || "5432") << " "
        flags << "--username=" << quote(@params["login_user"]? || "postgres")
      end
    end

    private def quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end

    # Writes dump content to target, gzip-compressing natively (no `gzip`
    # subprocess) when target ends in .gz.
    private def write_target(target : String, content : String)
      if target.ends_with?(".gz")
        File.open(target, "w") do |file|
          Compress::Gzip::Writer.open(file, &.print(content))
        end
      else
        File.write(target, content)
      end
    end

    # Returns a path to plain SQL content ready for `psql --file=path`:
    # target itself when it's already plain, or a decompressed temp copy
    # when target ends in .gz (native `Compress::Gzip::Reader`, no `gzip`
    # subprocess) - the caller deletes the temp copy afterward.
    private def read_target_as_sql_file(target : String) : String
      return target unless target.ends_with?(".gz")

      tmp_path = "#{target}.#{Process.pid}.sql"
      File.open(target) do |file|
        Compress::Gzip::Reader.open(file) do |reader|
          File.write(tmp_path, reader.gets_to_end)
        end
      end
      tmp_path
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

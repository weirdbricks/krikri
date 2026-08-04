#!/usr/bin/env crystal

require "json"
require "pg"
require "compress/gzip"
require "xz"
require "bz2"
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
  #   logical SQL dump." `target:` is required for both. The plain `.sql`
  #   format is natively compressed via
  #   `Compress::Gzip`/`Compress::XZ`/`Compress::BZ2` (`.gz`/`.xz`/`.bz2`)
  #   rather than shelling to `gzip`/`xz`/`bzip2` (matching `mysql_db.cr`'s
  #   own reasoning; real Ansible's postgresql_db has no `.zst` support
  #   at all to begin with, unlike mysql_db - verified against its
  #   source, not assumed just because mysql_db has one). `.tar`/`.pgc`/
  #   `.dir` (real Ansible's own `pg_dump --format=t/c/d`) are supported
  #   too: dump has `pg_dump` write straight to `target:` via a shell
  #   redirect/`-f` flag rather than going through this plugin's own
  #   String-based capture-then-write path (binary-unsafe for these three
  #   - see PG_RESTORE_FORMATS' own doc comment), and restore shells out
  #   to `pg_restore` instead of `psql` for exactly these three
  #   extensions, a genuinely different restore mechanism, not just
  #   another compression codec (matches real Ansible's own
  #   `db_restore()` doing the same). Password passed via a `PGPASSWORD=`
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
  # Not implemented: `collation:`/`lc_collate:`/`lc_ctype:`/`template:`/
  # `tablespace:`, `force:` (terminate other connections before DROP
  # DATABASE), `session_role:`, `trust_input:` (SQL-injection guard on
  # option values - this plugin always quotes identifiers itself
  # instead), `target_opts:`/`dump_extra_args:` (extra pg_dump/pg_restore/
  # psql CLI args).
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

    # .tar/.pgc/.dir formats (see PG_RESTORE_FORMATS below) are binary
    # (.dir isn't even a single file) - remote_exec captures a command's
    # stdout as a Crystal String, which isn't safe for binary data
    # (established elsewhere in this codebase, see apt_repository.cr's
    # own GPG-key-export reasoning), so unlike the plain-.sql path below,
    # pg_dump is told to write straight to target itself via a shell
    # redirect/-f flag - the bytes never pass through Crystal at all.
    PG_RESTORE_FORMATS = {".tar" => "t", ".pgc" => "c", ".dir" => "d"}

    private def run_dump(name : String, target : String) : PluginResult
      ext = File.extname(target)
      if letter = PG_RESTORE_FORMATS[ext]?
        return run_dump_via_pg_dump_format(name, target, ext, letter)
      end

      cmd = "#{pgpassword_prefix}pg_dump #{quote(name)} #{login_flags}"
      result = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true, msg: result[:stderr], rc: result[:exit_code]) unless result[:exit_code] == 0

      write_target(target, result[:stdout])
      PluginResult.new(changed: true, failed: false, msg: "", rc: result[:exit_code])
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to write dump to #{target}: #{ex.message}")
    end

    # .dir needs `-f target` (pg_dump creates the directory itself);
    # .tar/.pgc are single files, written via a plain `>` shell redirect -
    # same distinction real Ansible's own db_dump() makes.
    private def run_dump_via_pg_dump_format(name : String, target : String, ext : String, format_letter : String) : PluginResult
      cmd = "#{pgpassword_prefix}pg_dump #{quote(name)} #{login_flags} --format=#{format_letter}"
      cmd += ext == ".dir" ? " -f #{quote(target)}" : " > #{quote(target)}"

      result = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true, msg: result[:stderr], rc: result[:exit_code]) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: "", rc: result[:exit_code])
    end

    private def run_restore(name : String, target : String) : PluginResult
      ext = File.extname(target)
      if PG_RESTORE_FORMATS.has_key?(ext)
        return run_restore_via_pg_restore(name, target, ext)
      end

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

    # pg_restore, not psql, handles .tar/.pgc/.dir - a genuinely different
    # restore mechanism, not just another compression codec (matches real
    # Ansible's own db_restore(): `cmd = module.get_bin_path('pg_restore',
    # True)` for exactly these three extensions). Takes the target
    # path/directory as a positional argument rather than stdin
    # redirection, unlike psql's plain-.sql path above.
    private def run_restore_via_pg_restore(name : String, target : String, ext : String) : PluginResult
      exists = ext == ".dir" ? remote_dir_exists?(target) : remote_file_exists?(target)
      return PluginResult.new(changed: false, failed: true, msg: "target #{target} does not exist") unless exists

      cmd = "#{pgpassword_prefix}pg_restore --dbname=#{quote(name)} #{login_flags} #{quote(target)}"
      result = remote_exec(cmd)

      return PluginResult.new(changed: false, failed: true, msg: result[:stderr], rc: result[:exit_code]) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: result[:stdout], rc: result[:exit_code])
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

    # Writes dump content to target, compressing natively (no `gzip`/
    # `bzip2`/`xz` subprocess) when target ends in .gz/.bz2/.xz.
    private def write_target(target : String, content : String)
      File.open(target, "w") do |file|
        case
        when target.ends_with?(".gz")
          Compress::Gzip::Writer.open(file, &.print(content))
        when target.ends_with?(".bz2")
          Compress::BZ2::Writer.open(file, &.print(content))
        when target.ends_with?(".xz")
          Compress::XZ::Writer.open(file, &.print(content))
        else
          file.print(content)
        end
      end
    end

    # Returns a path to plain SQL content ready for `psql --file=path`:
    # target itself when it's already plain, or a decompressed temp copy
    # when target ends in .gz/.bz2/.xz (native readers, no subprocess) -
    # the caller deletes the temp copy afterward.
    private def read_target_as_sql_file(target : String) : String
      return target unless target.ends_with?(".gz") || target.ends_with?(".bz2") || target.ends_with?(".xz")

      tmp_path = "#{target}.#{Process.pid}.sql"
      content = File.open(target) do |file|
        if target.ends_with?(".gz")
          Compress::Gzip::Reader.open(file, &.gets_to_end)
        elsif target.ends_with?(".bz2")
          Compress::BZ2::Reader.open(file, &.gets_to_end)
        else
          Compress::XZ::Reader.open(file, &.gets_to_end)
        end
      end
      File.write(tmp_path, content)
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

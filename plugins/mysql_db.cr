#!/usr/bin/env crystal

require "json"
require "mysql"
require "compress/gzip"
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
  # - state: dump / import: shells out to `mysqldump`/`mysql` (real
  #   Ansible's own module does the same - dump/restore need the actual
  #   client binaries, there's no wire-protocol equivalent of "give me a
  #   full logical SQL dump"). `target:` is required for both. Real
  #   Ansible pipes dump/import through `gzip`/`bzip2`/`xz` shell
  #   binaries for a compressed `target:`; this plugin instead reads/
  #   writes the compressed file natively via Crystal's own stdlib
  #   `Compress::Gzip` (only `.gz` - `.bz2`/`.xz` are a documented scope
  #   cut, see below) rather than shelling to `gzip`, matching this
  #   codebase's general preference for native codecs over shelling out
  #   where one's already available (`archive.cr` already depends on
  #   `Compress::Gzip` for the same reason). Command shape (`mysqldump
  #   --user=U --password='PW' --host=H --port=P dbname --quick` /
  #   `mysql --user=U --password='PW' --host=H --port=P --one-database
  #   dbname < target`, including the `--quick`/`--one-database` flags
  #   defaulting on) and the always-`changed: true`-on-success behavior
  #   (dump/import are not idempotency-checked at all, unlike
  #   present/absent above) verified against a real `ansible-playbook`
  #   run with `community.mysql.mysql_db` against a real MariaDB 11
  #   server, not assumed from the docs.
  # - check_mode
  #
  # Not implemented: `.bz2`/`.xz`/`.zst` compression for dump/import
  # (only `.gz`, see above), `config_file:` (`~/.my.cnf` credential
  # lookup), `all_databases:`, `ignore_tables:`/`hex_blob:`/
  # `master_data:`/`dump_extra_args:`/`single_transaction:`/
  # `skip_lock_tables:` (mysqldump tuning knobs), encoding:/collation:
  # validation against the server's actually supported charsets - an
  # invalid value is passed straight through and surfaces as whatever
  # error the server itself returns.
  class MysqlDbPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      if state == "dump" || state == "import"
        return run_dump_or_import(state, name)
      end

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

    private def run_dump_or_import(state : String, name : String) : PluginResult
      target = @params["target"]?
      return PluginResult.new(changed: false, failed: true, msg: "target is required when state is dump or import") unless target

      check_mode = is_true?(@params["check_mode"]?)
      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would #{state} database #{name} #{state == "dump" ? "to" : "from"} #{target} (check mode)")
      end

      state == "dump" ? run_dump(name, target) : run_import(name, target)
    end

    private def run_dump(name : String, target : String) : PluginResult
      cmd = "mysqldump #{login_flags} #{quote(name)} --quick"
      result = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true, msg: result[:stderr]) unless result[:exit_code] == 0

      write_target(target, result[:stdout])
      PluginResult.new(changed: true, failed: false, msg: "", db: name, db_list: [name])
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to write dump to #{target}: #{ex.message}")
    end

    private def run_import(name : String, target : String) : PluginResult
      return PluginResult.new(changed: false, failed: true, msg: "target #{target} does not exist") unless remote_file_exists?(target)

      sql_path = read_target_as_sql_file(target)
      cmd = "mysql #{login_flags} --one-database #{quote(name)} < #{quote(sql_path)}"
      result = remote_exec(cmd)
      File.delete?(sql_path) if sql_path != target

      return PluginResult.new(changed: false, failed: true, msg: result[:stderr]) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: "", db: name, db_list: [name])
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to import #{target}: #{ex.message}")
    end

    private def login_flags : String
      String.build do |flags|
        flags << "--user=" << quote(@params["login_user"]) << " " if @params["login_user"]?
        flags << "--password=" << quote(@params["login_password"]) << " " if @params["login_password"]?
        if socket = @params["login_unix_socket"]?
          flags << "--socket=" << quote(socket) << " "
        else
          flags << "--host=" << quote(@params["login_host"]? || "localhost") << " "
          flags << "--port=" << (@params["login_port"]? || "3306") << " "
        end
      end.strip
    end

    # Shell-quotes a value for interpolation into a remote_exec command
    # (same helper as postgresql_db.cr's) - login values and the db name
    # all flow into a /bin/bash -c command line, so an embedded quote has
    # to be escaped, not just wrapped.
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

    # Returns a path to plain SQL content ready for `mysql ... < path`:
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

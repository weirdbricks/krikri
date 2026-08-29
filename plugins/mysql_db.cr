#!/usr/bin/env crystal

require "json"
require "mysql"
require "compress/gzip"
require "xz"
require "bz2"
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
  #   Ansible pipes dump/import through `gzip`/`bzip2`/`xz`/`zstd` shell
  #   binaries for a compressed `target:`; this plugin instead reads/
  #   writes `.gz`/`.xz`/`.bz2` natively via `Compress::Gzip`
  #   (stdlib)/`Compress::XZ`/`Compress::BZ2`, matching this codebase's
  #   general preference for native codecs over shelling out where one's
  #   already available (`archive.cr` already depends on all three for
  #   the same reason) - `.zst` shells out to the `zstd` CLI binary
  #   instead (no Crystal zstd binding vendored here), which is actually
  #   what real Ansible's own module does for `.zst` too
  #   (`module.get_bin_path('zstd', True)`, piped through a subprocess -
  #   verified against its actual source), so this one codec isn't a step
  #   down from real Ansible's own behavior the way it would be for the
  #   other three. Command shape (`mysqldump
  #   --user=U --password='PW' --host=H --port=P dbname --quick` /
  #   `mysql --user=U --password='PW' --host=H --port=P --one-database
  #   dbname < target`, including the `--quick`/`--one-database` flags
  #   defaulting on) and the always-`changed: true`-on-success behavior
  #   (dump/import are not idempotency-checked at all, unlike
  #   present/absent above) verified against a real `ansible-playbook`
  #   run with `community.mysql.mysql_db` against a real MariaDB 11
  #   server, not assumed from the docs.
  # - state: dump/import only: `config_file:` (a `my.cnf`-format options
  #   file, passed as `--defaults-extra-file=` - real Ansible's own
  #   mysqldump/mysql invocation demands this be the very first flag, so
  #   it's built first here too, not just appended anywhere) /
  #   `restrict_config_file:` (bool - `--defaults-file=` instead, meaning
  #   *only* `config_file:` is read, no other implicit option files).
  #   `name: all` (real Ansible has no separate `all_databases:` boolean
  #   param at all despite this plugin's own prior doc comment claiming
  #   otherwise - verified against its actual `argument_spec` - it's
  #   triggered by passing the literal db name `all`) uses
  #   `--all-databases` for dump and skips `--one-database <name>`
  #   entirely for import, matching real Ansible's own `db_dump`/
  #   `db_import`.
  # - state: dump only: `single_transaction:`/`skip_lock_tables:`/
  #   `hex_blob:` (bools), `ignore_tables:` (comma-separated
  #   `database_name.table_name` entries, one `--ignore-table=` per
  #   entry), `master_data:` (0 (default, omitted)/1/2 -
  #   `--master-data=N`; real Ansible switches to `--source-data=N` for
  #   MySQL, not MariaDB, servers at 8.2.0+, a version/implementation
  #   check this plugin doesn't replicate - `--master-data=` is accepted
  #   by every server this project targets, a documented simplification),
  #   `dump_extra_args:` (a raw string appended as-is, same "no
  #   validation, passed straight through" treatment as `mysqldump`
  #   itself gives it).
  # - check_mode
  #
  # Not implemented: encoding:/collation: validation against the
  # server's actually supported charsets - an invalid value is passed
  # straight through and surfaces as whatever error the server itself
  # returns; dump/import's own `--default-character-set=`.
  class MysqlDbPlugin < BasePlugin
    def execute : PluginResult
      # Real Ansible's `name:` param has `aliases: [db]` - same bug
      # class fixed for postgresql_db/postgresql_user in round 43
      # (robertdebock.postgres): a real playbook writing `db: mydb`
      # (the alias) got "missing required argument: name" no matter
      # what `db:` was set to.
      name = @params["name"]? || @params["db"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)

      if state == "dump" || state == "import"
        return run_dump_or_import(state, name)
      end

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
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

      check_mode = true?(@params["check_mode"]?)
      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would #{state} database #{name} #{state == "dump" ? "to" : "from"} #{target} (check mode)")
      end

      state == "dump" ? run_dump(name, target) : run_import(name, target)
    end

    private def run_dump(name : String, target : String) : PluginResult
      all_databases = name == "all"

      cmd = String.build do |cmd_str|
        cmd_str << "mysqldump " << config_file_flag << login_flags << " "
        cmd_str << (all_databases ? "--all-databases" : quote(name))
        cmd_str << " --skip-lock-tables" if true?(@params["skip_lock_tables"]?)
        cmd_str << " --single-transaction=true" if true?(@params["single_transaction"]?)
        cmd_str << " --quick"
        ignore_tables.each { |table| cmd_str << " --ignore-table=" << quote(table) }
        cmd_str << " --hex-blob" if true?(@params["hex_blob"]?)
        if master_data = @params["master_data"]?
          cmd_str << " --master-data=" << master_data unless master_data == "0"
        end
        cmd_str << " " << @params["dump_extra_args"] if @params["dump_extra_args"]?
      end

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
      cmd = String.build do |cmd_str|
        cmd_str << "mysql " << config_file_flag << login_flags
        cmd_str << " --one-database " << quote(name) unless name == "all"
      end
      cmd += " < #{quote(sql_path)}"
      result = remote_exec(cmd)
      File.delete?(sql_path) if sql_path != target

      return PluginResult.new(changed: false, failed: true, msg: result[:stderr]) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: "", db: name, db_list: [name])
    rescue ex
      PluginResult.new(changed: false, failed: true, msg: "Failed to import #{target}: #{ex.message}")
    end

    # mysqldump/mysql demand --defaults-extra-file/--defaults-file be the
    # very first option - built and prepended separately from
    # login_flags for that reason, not folded into it.
    private def config_file_flag : String
      config_file = @params["config_file"]?
      return "" unless config_file

      flag = true?(@params["restrict_config_file"]?) ? "--defaults-file=" : "--defaults-extra-file="
      "#{flag}#{quote(config_file)} "
    end

    private def ignore_tables : Array(String)
      @params["ignore_tables"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
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

    # Writes dump content to target, compressing natively (no `gzip`/
    # `bzip2`/`xz` subprocess) when target ends in .gz/.bz2/.xz - same
    # codecs (and the same "native over shelling out" preference)
    # archive.cr already depends on. .zst shells out to the `zstd` CLI
    # binary instead - no Crystal zstd binding is vendored in this
    # codebase, but real Ansible's own module does exactly the same
    # thing for `.zst` (`module.get_bin_path('zstd', True)`, piped
    # through a subprocess - verified against its actual source, unlike
    # gzip/bzip2/xz, which real Ansible *also* shells out to but this
    # codebase deliberately went native for since bindings already
    # existed), so this is arguably more faithful to real Ansible's own
    # implementation than the other three, not less.
    private def write_target(target : String, content : String)
      return write_zst(target, content) if target.ends_with?(".zst")

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

    private def write_zst(target : String, content : String)
      status = Process.run("zstd", ["-q", "-f", "-o", target, "-"], input: IO::Memory.new(content))
      raise "zstd compression failed (exit #{status.exit_code}) - is the zstd binary installed?" unless status.success?
    end

    # Returns a path to plain SQL content ready for `mysql ... < path`:
    # target itself when it's already plain, or a decompressed temp copy
    # when target ends in .gz/.bz2/.xz/.zst (native readers for the first
    # three, `zstd -dc` subprocess for the last - see write_target above)
    # - the caller deletes the temp copy afterward.
    private def read_target_as_sql_file(target : String) : String
      return read_zst_as_sql_file(target) if target.ends_with?(".zst")
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

    private def read_zst_as_sql_file(target : String) : String
      tmp_path = "#{target}.#{Process.pid}.sql"
      status = File.open(tmp_path, "w") do |outfile|
        Process.run("zstd", ["-q", "-d", "-c", target], output: outfile)
      end
      raise "zstd decompression failed (exit #{status.exit_code}) - is the zstd binary installed?" unless status.success?
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

#!/usr/bin/env crystal

require "json"
require "mysql"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/db_errors"
require "../src/krikri/plugin_helpers/mysql_connection"
require "../src/krikri/plugin_helpers/mysql_privileges"
require "../src/krikri/plugin_helpers/sql_quoting"

module Krikri
  # MySQL user plugin - creates/removes a user and manages its
  # privileges. Compatible with Ansible's community.mysql.mysql_user
  # module.
  #
  # See plugins/mysql_db.cr's module comment for the shared architecture
  # note (talks to the server directly over MySQL's own wire protocol via
  # a fork of crystal-lang/crystal-mysql).
  #
  # Supported parameters:
  # - name: username (required)
  # - password: only applied when creating a new user, or when an
  #   existing user's password is updated (update_password: always,
  #   the default - see below)
  # - host: the 'host' part of user@host (default "localhost", matching
  #   real Ansible's own default - not "%")
  # - state: present (default) / absent
  # - priv: "db.table:PRIV1,PRIV2" (multiple grants separated by "/"),
  #   same format real Ansible's mysql_user uses - see
  #   src/krikri/plugin_helpers/mysql_privileges.cr. Diffed against
  #   the account's actual SHOW GRANTS output; a mismatch REVOKEs
  #   everything and re-GRANTs the desired set from scratch rather than
  #   computing a minimal add/remove delta - simpler, and idempotent
  #   either way, just not the smallest possible set of statements.
  # - update_password: "always" (default, matching real Ansible) or
  #   "on_create". "always" compares the account's current password hash
  #   (mysql.user.authentication_string) against the mysql_native_password
  #   hash of the given password (computed by the server, the way real
  #   does) before deciding whether an ALTER is even needed - matching
  #   real Ansible's own idempotent behavior (round 18; was previously an
  #   unconditional ALTER + changed: true on every run).
  # - plugin/plugin_hash_string/plugin_auth_string: non-password
  #   authentication, matching real Ansible's own mysql_user module
  #   (verified against community.mysql's module_utils/user.py). Auth
  #   clause precedence (highest first): password, then
  #   plugin+plugin_hash_string (`IDENTIFIED WITH <p> AS <hash>`), then
  #   plugin+plugin_auth_string (`IDENTIFIED WITH <p> BY <auth>`, with
  #   MariaDB's pam->USING and ed25519->USING PASSWORD() special cases),
  #   then bare plugin (`IDENTIFIED WITH <p>`). weaponized for creating
  #   unix_socket/auth_socket accounts (the common MariaDB/Debian root
  #   pattern): `plugin: unix_socket` -> `CREATE USER ... IDENTIFIED WITH
  #   unix_socket`. The update path diffs current plugin+authentication_
  #   string against the desired and only ALTERs on a real change.
  # - login_host/login_port/login_user/login_password/login_unix_socket
  # - check_mode
  # - host_all: operate on every existing host row for name: instead of
  #   a single host: - see #ensure_present_all_hosts/#ensure_absent_
  #   all_hosts. priv: is not applied in this mode (dev-sec mysql_
  #   hardening's own two host_all: callers - root's password and
  #   removing anonymous users - never combine it with priv: either).
  #
  # Not implemented: update_password: on_new_username, salt:, append_privs:/
  # subtract_privs: (this always does a full revoke-then-regrant instead),
  # resource_limits:, locked:, config_file:.
  class MysqlUserPlugin < BasePlugin
    # Carries the fail_json msg real's module would produce for a server
    # rejection of a password/plugin auth statement, out of the deep
    # statement helpers to #execute's rescue.
    private class AuthStatementError < Exception; end

    # Real 2.19.11 + community.mysql 5.0.2 (live-verified, `{{ r |
    # to_json }}`, MySQL 8.4): the module's own exit_json kwargs, in its
    # own order - changed, user, msg, password_changed, attributes,
    # failed. `user` is the `name:` param echoed verbatim (a bare name
    # with no `host:`, exactly as written), `password_changed` is null
    # only on the check-mode create (where nothing was attempted) and
    # `attributes` is null unless `attributes:` was given.
    private SUCCESS_KEY_ORDER = %w[changed user msg password_changed attributes failed]

    # What real reports for whether the account's password was (re)set -
    # tracked through the run and attached to the result in #with_shape.
    @password_changed : JSON::Any? = JSON::Any.new(false)

    def execute : PluginResult
      # Real's `name:` param has NO `user:` alias (verified against the
      # installed ansible.mysql 5.2.0 module source, which
      # community.mysql's plugin_routing redirects to: real rejects
      # `user:` with "Unsupported parameters for (mysql_user) module:
      # user"). That rejection happens in real's argument-spec check,
      # which krikri runs controller-side before this plugin is ever
      # reached; keep the plugin itself reading the canonical name only.
      name = @params["name"]?
      unless name
        # Real AnsibleModule's own required-arguments failure is plural
        # "arguments" even for a single missing param (same wording the
        # dpkg_selections fix aligned to) - live-verified against
        # community.mysql.mysql_user via the podman-diff
        # mysql_user_edge_cases W8 harness case.
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: name")
      end

      host = @params["host"]? || "localhost"
      state = @params["state"]? || "present"
      # Real community.mysql's argument-spec choices check fails the
      # task BEFORE any connection attempt; this engine accepted any
      # unknown state as if it were present and CREATED the account
      # (W7: state: present-nowhere reported changed=true "User added")
      # where real Ansible fails with the standard choices message
      # (live-verified, same harness case).
      unless ["present", "absent"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: absent, present, got: #{state}")
      end
      password = @params["password"]?
      priv = @params["priv"]?
      update_password = @params["update_password"]? || "always"
      check_mode = true?(@params["_ansible_check_mode"]?)
      host_all = true?(@params["host_all"]?)

      plugin = @params["plugin"]?
      plugin_hash_string = @params["plugin_hash_string"]?
      plugin_auth_string = @params["plugin_auth_string"]?

      if err = validate_inputs(update_password, password, plugin, plugin_hash_string, plugin_auth_string)
        return err
      end

      uri = PluginHelpers::MysqlConnection.build_uri(
        host: @params["login_host"]?,
        port: @params["login_port"]?,
        user: @params["login_user"]?,
        password: @params["login_password"]?,
        unix_socket: @params["login_unix_socket"]?,
        config_file: @params["config_file"]? || "~/.my.cnf",
      )

      with_shape(
        run_with_db(uri, name, host, state, password, update_password, priv, plugin,
          plugin_hash_string, plugin_auth_string, check_mode, host_all),
        name
      )
    rescue ex : AuthStatementError
      PluginResult.new(changed: false, failed: true, msg: ex.message || "")
    rescue ex : DB::ConnectionRefused
      # community.mysql's own connection-failure wrapper (live-verified
      # against bookworm's community.mysql 3.x via the W9 harness case,
      # where this engine printed the generic DbErrors shape with an
      # EMPTY detail tail). The Exception-message tail after the
      # wrapper is PyMySQL-specific (an (errno, "...") repr) and is not
      # replicated; the deterministic wrapper is the parity that
      # matters. mysql_db/mysql_info/mysql_variables keep DbErrors's
      # generic shape until their own harness cases say otherwise.
      PluginResult.new(changed: false, failed: true,
        msg: "unable to connect to database, check login_user and login_password are correct or /root/.my.cnf has the credentials. Exception message: #{ex.message}")
    rescue ex : MySql::Connection::PacketError
      PluginHelpers::DbErrors.query_failed(ex, "MySQL")
    end

    # Re-emits a result with real's registered keys attached. Only the
    # SUCCESS paths carry them; a fail_json keeps the plain failure shape
    # real's own fail_json produces.
    private def with_shape(result : PluginResult, name : String) : PluginResult
      return result if result.failed?

      PluginResult.new(
        changed: result.changed?,
        failed: false,
        msg: result.msg,
        user: name,
        password_changed: @password_changed,
        attributes: desired_attributes,
        failed_flag: true,
        key_order: SUCCESS_KEY_ORDER
      )
    end

    # Real reports the attributes the SERVER ended up storing, which is
    # only ever something when `attributes:` was given; null otherwise.
    private def desired_attributes : JSON::Any
      attributes = @params["attributes"]?
      return JSON::Any.new(nil) unless attributes
      (JSON.parse(attributes) rescue JSON::Any.new(attributes))
    end

    private def validate_inputs(update_password : String, password : String?, plugin : String?,
                                plugin_hash_string : String?, plugin_auth_string : String?) : PluginResult?
      unless ["always", "on_create"].includes?(update_password)
        return PluginResult.new(changed: false, failed: true, msg: "update_password must be 'always' or 'on_create', got '#{update_password}'")
      end

      if password && plugin
        return PluginResult.new(changed: false, failed: true, msg: "password and plugin are mutually exclusive")
      end

      if plugin_hash_string && plugin_auth_string
        return PluginResult.new(changed: false, failed: true, msg: "plugin_hash_string and plugin_auth_string are mutually exclusive")
      end

      if (plugin_hash_string || plugin_auth_string) && !plugin
        return PluginResult.new(changed: false, failed: true, msg: "plugin is required when plugin_hash_string or plugin_auth_string is given")
      end

      nil
    end

    private def run_with_db(uri : String, name : String, host : String, state : String, password : String?,
                            update_password : String, priv : String?, plugin : String?,
                            plugin_hash_string : String?, plugin_auth_string : String?,
                            check_mode : Bool, host_all : Bool) : PluginResult
      DB.open(uri) do |connection|
        if host_all
          run_host_all(connection, name, state, password, update_password, host,
            plugin, plugin_hash_string, plugin_auth_string, check_mode)
        else
          run_single_host(connection, name, host, state, password, update_password, priv,
            plugin, plugin_hash_string, plugin_auth_string, check_mode)
        end
      end
    end

    private def run_host_all(connection : DB::Database, name : String, state : String,
                             password : String?, update_password : String, host : String,
                             plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?,
                             check_mode : Bool) : PluginResult
      existing_hosts = user_hosts(connection, name)
      if state == "absent"
        ensure_absent_all_hosts(connection, name, existing_hosts, check_mode)
      else
        ensure_present_all_hosts(connection, name, existing_hosts, host, password, update_password,
          plugin, plugin_hash_string, plugin_auth_string, check_mode)
      end
    end

    private def run_single_host(connection : DB::Database, name : String, host : String,
                                state : String, password : String?, update_password : String,
                                priv : String?, plugin : String?, plugin_hash_string : String?,
                                plugin_auth_string : String?, check_mode : Bool) : PluginResult
      exists = user_exists?(connection, name, host)

      if state == "absent"
        ensure_absent(connection, name, host, exists, check_mode)
      else
        ensure_present(connection, name, host, exists, password, update_password, priv,
          plugin, plugin_hash_string, plugin_auth_string, check_mode)
      end
    end

    private def ensure_present(
      db : DB::Database, name : String, host : String, exists : Bool,
      password : String?, update_password : String, priv : String?,
      plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?, check_mode : Bool,
    ) : PluginResult
      early, changed, created = create_or_update_account(db, name, host, exists, password, update_password,
        plugin, plugin_hash_string, plugin_auth_string, check_mode)
      return early if early

      early, changed = apply_priv_if_needed(db, name, host, exists, changed, priv, check_mode)
      return early if early

      # Real Ansible branches the success msg on create-vs-modify (its own
      # user_add sets msg to "User added" when the account genuinely didn't
      # exist), not on `changed` - a brand-new create is not an "update".
      msg = if created
              "User added"
            elsif changed
              "User updated"
            else
              "User unchanged"
            end
      PluginResult.new(changed: changed, failed: false, msg: msg)
    end

    # Creates the account if it doesn't exist yet, or updates its
    # password if it does (and update_password: is "always"). Returns
    # {early_result, changed} - early_result is non-nil only for a
    # check-mode short-circuit, which the caller returns immediately.
    private def create_or_update_account(
      db : DB::Database, name : String, host : String, exists : Bool,
      password : String?, update_password : String,
      plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?, check_mode : Bool,
    ) : {PluginResult?, Bool, Bool}
      unless exists
        if check_mode
          @password_changed = JSON::Any.new(nil)
          return {PluginResult.new(changed: true, failed: false, msg: "User added"), false, true}
        end

        clause = build_auth_clause(db, password, plugin, plugin_hash_string, plugin_auth_string)
        exec_auth_statement db, "CREATE USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        @password_changed = JSON::Any.new(true)
        return {nil, true, true}
      end

      return {nil, false, false} unless update_password == "always"
      return {nil, false, false} unless password || plugin

      if password
        plugin_or_password_update(db, name, host, password, update_password, check_mode)
      else
        # Non-password auth: diff the account's current plugin (and, when a
        # hash/auth string was given, its authentication_string) against the
        # desired value, ALTERing only on a real change - matching real
        # Ansible's own plugin idempotency. Bare `plugin: unix_socket`/`auth_socket`
        # (the auth_socket account pattern) compares the plugin column only.
        pl = plugin || return {nil, false, false}
        return {nil, false, false} if plugin_matches?(db, name, host, pl, plugin_hash_string, plugin_auth_string)

        if check_mode
          return {PluginResult.new(changed: true, failed: false, msg: "User updated"), false, false}
        end

        clause = build_auth_clause(db, nil, plugin, plugin_hash_string, plugin_auth_string)
        exec_auth_statement db, "ALTER USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        @password_changed = JSON::Any.new(true)
        {nil, true, false}
      end
    end

    private def plugin_or_password_update(
      db : DB::Database, name : String, host : String, password : String,
      update_password : String, check_mode : Bool,
    ) : {PluginResult?, Bool, Bool}
      # Real bug found benchmarking robertdebock.mysql's own "Create
      # users" task (round 18): update_password: always (the default,
      # matching real Ansible - the role leaves it unset) previously
      # reissued ALTER USER ... IDENTIFIED BY unconditionally on every
      # run, reporting changed: true even when the password was already
      # exactly what was requested - a genuine idempotency divergence
      # from real ansible-playbook, which compares the account's current
      # password hash (mysql.user.authentication_string, the
      # mysql_native_password/MariaDB format) against what the given
      # password WOULD hash to (`SELECT CONCAT('*', UCASE(SHA1(UNHEX(
      # SHA1(...)))))) - the same hash real then hands to
      # `ALTER USER ... IDENTIFIED WITH mysql_native_password AS ...`
      # on the update path - before deciding whether an ALTER is even
      # needed.
      hash = native_password_hash(db, password)
      if password_already_matches?(db, name, host, hash)
        return {nil, false, false}
      end

      return {PluginResult.new(changed: true, failed: false, msg: "User updated"), false, false} if check_mode

      exec_auth_statement db, "ALTER USER #{quote_str(name)}@#{quote_str(host)} IDENTIFIED WITH mysql_native_password AS #{quote_str(hash)}"
      @password_changed = JSON::Any.new(true)
      {nil, true, false}
    end

    # Builds the CREATE/ALTER USER auth clause, matching real Ansible's
    # mysql_user module precedence (community.mysql module_utils/user.py):
    # password first, then plugin+hash (`IDENTIFIED WITH p AS hash`), then
    # plugin+auth_string (`IDENTIFIED WITH p BY auth`, with MariaDB pam ->
    # USING and ed25519 -> USING PASSWORD() special cases), then bare
    # plugin (`IDENTIFIED WITH p`). The plugin name is interpolated as a
    # single-quoted string literal (quote_str), matching how real Ansible
    # reaches the server with it (a bound query parameter) - MySQL accepts
    # a quoted string where the auth plugin name goes, and a raw
    # interpolation would let `plugin:` carry arbitrary SQL.
    #
    # A password with no `plugin:` is real's DEFAULT-PLUGIN path: it does
    # NOT let the server pick its default - real hashes the password
    # itself (`SELECT CONCAT('*', UCASE(SHA1(UNHEX(SHA1(...)))))`) and
    # issues `IDENTIFIED WITH mysql_native_password AS '<hash>'`
    # (module_utils/user.py's user_add/user_mod), so the account lands on
    # mysql_native_password even where the server default is
    # caching_sha2_password, and a server where that plugin is not loaded
    # (MySQL 8.4+ disabled it by default; it is gone from 9.7 on) rejects
    # the statement with error 1524 - the failure real surfaces, and the
    # detection the module effectively relies on (it version-gates the
    # same statement at 9.7; the server's own rejection is what actually
    # decides here). The hash round trip is the only statement real
    # issues first, so krikri does the same - no version sniffing.
    private def build_auth_clause(
      db : DB::Database, password : String?, plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?,
    ) : String
      if password
        " IDENTIFIED WITH mysql_native_password AS #{quote_str(native_password_hash(db, password))}"
      elsif plugin && plugin_hash_string
        " IDENTIFIED WITH #{quote_str(plugin)} AS #{quote_str(plugin_hash_string)}"
      elsif plugin && plugin_auth_string
        if plugin == "pam"
          " IDENTIFIED WITH #{quote_str(plugin)} USING #{quote_str(plugin_auth_string)}"
        elsif plugin == "ed25519"
          " IDENTIFIED WITH #{quote_str(plugin)} USING PASSWORD(#{quote_str(plugin_auth_string)})"
        else
          " IDENTIFIED WITH #{quote_str(plugin)} BY #{quote_str(plugin_auth_string)}"
        end
      elsif plugin
        " IDENTIFIED WITH #{quote_str(plugin)}"
      else
        ""
      end
    end

    # True when the account's current plugin (and authentication_string,
    # when a hash/auth string was desired) already matches what was asked,
    # so no ALTER is needed.
    private def plugin_matches?(
      db : DB::Database, name : String, host : String, plugin : String,
      plugin_hash_string : String?, plugin_auth_string : String?,
    ) : Bool
      # Does the comparison entirely server-side (a boolean 0/1), rather
      # than pulling the raw column back through the driver as a value -
      # mysql.user's plugin/authentication_string columns are types this
      # vendored driver has no `read` for (the same "not supported read"
      # limitation password_already_matches? documents for the LONGTEXT
      # authentication_string). An integer result is a type every driver
      # here already reads fine.
      matches = db.query_all(
        "SELECT plugin = ? FROM mysql.user WHERE User = ? AND Host = ?",
        plugin, name, host, as: Int32
      ).first?
      return false unless matches == 1

      # Bare plugin (auth_socket/unix_socket pattern): a matching plugin
      # column is sufficient - no auth string to verify.
      return true unless plugin_hash_string || plugin_auth_string

      # With a hash/auth string, verify the account's authentication_string
      # matches server-side as well.
      want = plugin_hash_string || plugin_auth_string
      auth_matches = db.query_all(
        "SELECT authentication_string = ? FROM mysql.user WHERE User = ? AND Host = ?",
        want, name, host, as: Int32
      ).first?
      auth_matches == 1
    rescue
      false
    end

    # What the given plaintext password hashes to under
    # mysql_native_password, computed by the server itself the way real
    # computes it before every password-based CREATE/ALTER USER
    # (module_utils/user.py: `SELECT CONCAT('*',
    # UCASE(SHA1(UNHEX(SHA1(...)))))`).
    private def native_password_hash(db : DB::Database, password : String) : String
      db.query_one("SELECT CONCAT('*', UCASE(SHA1(UNHEX(SHA1(?)))))", password, as: String)
    rescue ex : MySql::Connection::PacketError
      raise mysql_auth_statement_error(ex)
    end

    # Runs a CREATE/ALTER USER auth statement, surfacing a server
    # rejection in the shape real's module fails with: its
    # `except mysql_driver.Error as e: module.fail_json(msg=to_native(e))`
    # passes pymysql's own str(Exception) through, which is the
    # `(errno, "message")` tuple form.
    private def exec_auth_statement(db : DB::Database, sql : String) : Nil
      db.exec sql
    rescue ex : MySql::Connection::PacketError
      raise mysql_auth_statement_error(ex)
    end

    # "Plugin '<name>' is not loaded" is ER_PLUGIN_IS_NOT_LOADED, always
    # this errno, on every MySQL/MariaDB server.
    private ER_PLUGIN_IS_NOT_LOADED = 1524

    # Wraps a driver PacketError in real's failure shape when the errno
    # is recoverable, re-raises it unchanged otherwise (the generic
    # DbErrors shape stays for everything the harness has not pinned).
    #
    # The vendored driver drops the server's errno when it raises
    # (handle_err_packet keeps only the message), but the message itself
    # pins the error for the one rejection this path expects - that is
    # exactly how a server without mysql_native_password loaded
    # (MySQL 8.4+ ships it disabled by default) rejects the
    # IDENTIFIED WITH mysql_native_password statement above, so the errno
    # is reconstructed rather than version-sniffed.
    private def mysql_auth_statement_error(ex : MySql::Connection::PacketError) : Exception
      message = ex.message || ""
      if plugin = message[/\APlugin '(.+)' is not loaded\z/, 1]?
        AuthStatementError.new("(#{ER_PLUGIN_IS_NOT_LOADED}, \"Plugin '#{plugin}' is not loaded\")")
      else
        ex
      end
    end

    # True when the account's current authentication_string already
    # equals the given mysql_native_password hash, so no ALTER is needed.
    private def password_already_matches?(db : DB::Database, name : String, host : String, hash : String) : Bool
      # Does the comparison entirely server-side (`authentication_string
      # = ?` against the precomputed hash, a boolean 0/1) rather than
      # pulling mysql.user.authentication_string back through the driver
      # as a value - that column is LONGTEXT on the wire, a MySQL
      # protocol type this vendored driver's type table has no `read`
      # for at all (`MySql::Type::LongBlob` has no override, only the
      # base `raise "not supported read"`). An integer result is a type
      # every driver here already reads fine. A NULL authentication
      # string compares as NULL (never equal), matching real's
      # current_pass_hash != encrypted_password on an unset password.
      matches = db.query_all(
        "SELECT authentication_string = ? FROM mysql.user WHERE User = ? AND Host = ?",
        hash, name, host, as: Int32
      ).first?
      matches == 1
    rescue
      false
    end

    # Applies priv: (if given) when it differs from the account's
    # current grants. Returns {early_result, changed} the same way
    # #create_or_update_account does - changed carries forward the
    # value the caller already had if nothing here needed to change.
    private def apply_priv_if_needed(
      db : DB::Database, name : String, host : String, exists : Bool, changed : Bool, priv : String?, check_mode : Bool,
    ) : {PluginResult?, Bool}
      return {nil, changed} unless priv

      desired = PluginHelpers::MysqlPrivileges.desired_grants(priv)
      current = exists && !changed ? current_grants(db, name, host) : Hash(String, Set(String)).new
      return {nil, changed} if current == desired

      return {PluginResult.new(changed: true, failed: false, msg: "User updated"), changed} if check_mode

      apply_grants(db, name, host, desired)
      {nil, true}
    end

    private def ensure_absent(db : DB::Database, name : String, host : String, exists : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User doesn't exist") unless exists
      return PluginResult.new(changed: true, failed: false, msg: "User deleted") if check_mode

      db.exec "DROP USER #{quote_str(name)}@#{quote_str(host)}"
      PluginResult.new(changed: true, failed: false, msg: "User deleted")
    end

    private def user_exists?(db : DB::Database, name : String, host : String) : Bool
      db.query_all("SELECT User FROM mysql.user WHERE User = ? AND Host = ?", name, host, as: String).size > 0
    end

    private def user_hosts(db : DB::Database, name : String) : Array(String)
      db.query_all("SELECT Host FROM mysql.user WHERE User = ?", name, as: String)
    end

    # `host_all: true` (dev-sec mysql_hardening's own "Ensure that the
    # root password is present" / "Ensure that anonymous users are
    # absent" tasks) operates on every existing host row for *name*
    # instead of a single `host:`. Real Ansible's own module: for
    # `present`, updates every existing account's password if any exist;
    # if none exist yet, falls back to creating exactly one account at
    # `host:` (default "localhost") - `host_all` alone never invents
    # more than one new account out of nothing.
    private def ensure_present_all_hosts(
      db : DB::Database, name : String, existing_hosts : Array(String), fallback_host : String,
      password : String?, update_password : String,
      plugin : String?, plugin_hash_string : String?, plugin_auth_string : String?, check_mode : Bool,
    ) : PluginResult
      if existing_hosts.empty?
        return ensure_present(db, name, fallback_host, false, password, update_password, nil,
          plugin, plugin_hash_string, plugin_auth_string, check_mode)
      end

      changed = false
      hash = password ? native_password_hash(db, password) : nil
      existing_hosts.each do |host|
        next unless needs_auth_update?(db, name, host, password, hash, update_password, plugin, plugin_hash_string, plugin_auth_string)
        return PluginResult.new(changed: true, failed: false, msg: "User updated") if check_mode

        clause = build_auth_clause(db, password, plugin, plugin_hash_string, plugin_auth_string)
        exec_auth_statement db, "ALTER USER #{quote_str(name)}@#{quote_str(host)}#{clause}"
        @password_changed = JSON::Any.new(true)
        changed = true
      end

      PluginResult.new(changed: changed, failed: false, msg: changed ? "User updated" : "User unchanged")
    end

    private def needs_auth_update?(db : DB::Database, name : String, host : String,
                                   password : String?, hash : String?, update_password : String, plugin : String?,
                                   plugin_hash_string : String?, plugin_auth_string : String?) : Bool
      return false unless update_password == "always" && (password || plugin)

      # Diff the existing hash (or plugin column, for non-password auth)
      # per host before deciding to ALTER, matching the per-host path's
      # idempotency (see the long comment in ensure_present_all_hosts's
      # original loop for the round-24 devsec.mysql_hardening bug).
      if password
        return false unless hash
        !password_already_matches?(db, name, host, hash)
      else
        pl = plugin || return false
        !plugin_matches?(db, name, host, pl, plugin_hash_string, plugin_auth_string)
      end
    end

    private def ensure_absent_all_hosts(db : DB::Database, name : String, existing_hosts : Array(String), check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User doesn't exist") if existing_hosts.empty?
      return PluginResult.new(changed: true, failed: false, msg: "User deleted") if check_mode

      existing_hosts.each { |host| db.exec "DROP USER #{quote_str(name)}@#{quote_str(host)}" }
      PluginResult.new(changed: true, failed: false, msg: "User deleted")
    end

    private def current_grants(db : DB::Database, name : String, host : String) : Hash(String, Set(String))
      rows = db.query_all("SHOW GRANTS FOR #{quote_str(name)}@#{quote_str(host)}", as: String)
      PluginHelpers::MysqlPrivileges.current_grants(rows)
    end

    private def apply_grants(db : DB::Database, name : String, host : String, desired : Hash(String, Set(String))) : Nil
      account = "#{quote_str(name)}@#{quote_str(host)}"

      db.exec "REVOKE ALL PRIVILEGES, GRANT OPTION FROM #{account}"

      desired.each do |target, privileges|
        grant_option = privileges.includes?("GRANT")
        list = privileges.reject { |priv_name| priv_name == "GRANT" }
        list = ["USAGE"] if list.empty?

        clause = grant_option ? " WITH GRANT OPTION" : ""
        db.exec "GRANT #{list.join(", ")} ON #{quote_target(target)} TO #{account}#{clause}"
      end
    end

    private def quote_str(s : String) : String
      PluginHelpers::SqlQuoting.quote_str(s)
    end

    private def quote_ident(s : String) : String
      PluginHelpers::SqlQuoting.mysql_quote_ident(s)
    end

    # "db.table" -> "`db`.`table`"; "*" components (db.* / *.*) are left
    # bare since MySQL's GRANT syntax doesn't accept a quoted wildcard.
    private def quote_target(target : String) : String
      db_part, _, table_part = target.partition('.')
      quoted_db = db_part == "*" ? "*" : quote_ident(db_part)
      quoted_table = table_part == "*" ? "*" : quote_ident(table_part)
      "#{quoted_db}.#{quoted_table}"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::MysqlUserPlugin.new(config)
plugin.run

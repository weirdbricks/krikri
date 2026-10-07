require "uri"
require "system/user"

module Krikri
  module PluginHelpers
    # MysqlConnection - building a mysql:// connection URI from
    # Ansible-style login_* params, with the same implicit `~/.my.cnf`
    # option-file fallback Ansible's own mysql_* modules rely on.
    # mysql_db/mysql_user/mysql_info/mysql_query do the actual DB.open.
    module MysqlConnection
      # The default option file every one of community.mysql's mysql_*
      # modules threads through as `config_file:` (its argument_spec
      # default is literally `~/.my.cnf`; the module reads it whenever it
      # exists, via the client lib's read_default_file). Explicit login_*
      # params always win over it - it only fills in what a task didn't
      # pass explicitly.
      DEFAULT_OPTION_FILE = "~/.my.cnf"

      # unix_socket, given, takes precedence over host/port (matches
      # Ansible's mysql_db/mysql_user own login_unix_socket precedence).
      #
      # Option-file handling mirrors community.mysql:
      # - config_file defaults to ~/.my.cnf, but is only read if the file
      #   actually exists (like upstream's os.path.exists config_file).
      # - Explicit login_user/login_password override the [client]
      #   user/password (upstream: "If login_user or login_password are
      #   given, they should override the config file").
      # - login_host/login_port are NOT taken from the option file (upstream
      #   keeps host=localhhost:3306 unless config_overrides_defaults:) -
      #   only user/password, plus socket as a fallback when no login_host
      #   was given, reach the URI.
      # login_host/login_port never come from the config file. A
      # config-file [client] socket is used when no login_unix_socket was
      # given and the login host is the implicit/explicit 'localhost'
      # (libmariadb's read_default_file [client] socket overrides its
      # compiled-in default in exactly that situation).
      #
      # Default-socket fallback (round 2300215, fiaasco.mariadb): when no
      # login_unix_socket is given, community.mysql hands its default
      # login_host of 'localhost' plus the port to the Python driver. On
      # the Debian-family target stacks these roles actually run on, that
      # driver is MySQLdb/libmariadb (the role installs python3-mysqldb;
      # community.mysql prefers PyMySQL but it isn't present), and
      # libmariadb maps a host of 'localhost' to its compiled-in
      # unix-socket path, NOT to TCP. That is how real ansible
      # bootstraps Debian's dual-auth root@localhost (native-password
      # 'invalid' OR unix_socket) through the socket as the OS root user
      # (SO_PEERCRED): live-verified on Ubuntu 24.04 + MariaDB 10.11,
      # MySQLdb root/'' host='localhost' connects over the socket while
      # host='127.0.0.1' is denied with errno 1698. Going TCP like PyMySQL
      # would get 'Access denied' there, which is exactly what this engine
      # did (all four mysql_user items of the role failed). The fallback
      # only picks a candidate path that actually exists - if none does
      # (no local server socket at a known location), we keep the TCP
      # behavior so a pure-TCP server still connects.
      def self.resolve_socket(unix_socket : String?, host : String?, defs : NamedTuple(user: String?, password: String?, socket: String?), exists : String -> Bool = ->(path : String) { File.exists?(path) }) : String?
        return unix_socket if unix_socket

        localhost = host.nil? || host == "localhost"
        return defs[:socket] if localhost && defs[:socket]
        return default_socket_file(exists) if localhost

        nil
      end

      # Compiled-in default socket paths of the client libraries that
      # resolve host 'localhost' to a socket (libmariadb/MySQLdb), per
      # packaging family. Debian/Ubuntu put the socket under /var/run/mysqld
      # (/var/run -> /run symlink); RHEL-family MariaDB packages use
      # /var/lib/mysql/mysql.sock; upstream tarballs/RPMs use /tmp/mysql.sock.
      DEFAULT_SOCKET_CANDIDATES = [
        "/var/run/mysqld/mysqld.sock",
        "/run/mysqld/mysqld.sock",
        "/var/lib/mysql/mysql.sock",
        "/tmp/mysql.sock",
      ]

      # First default socket path that exists on this host, or nil when
      # none does. `exists` is injectable so tests can exercise the
      # candidate ordering without a real MySQL server's socket files.
      def self.default_socket_file(exists : String -> Bool = ->(path : String) { File.exists?(path) }) : String?
        DEFAULT_SOCKET_CANDIDATES.find { |path| exists.call(path) }
      end

      private def self.build_base_uri(socket : String?, host : String?, port : String?) : URI
        if socket
          URI.new(scheme: "mysql", path: socket)
        else
          URI.new(scheme: "mysql", host: host || "localhost", port: (port || "3306").to_i)
        end
      end

      def self.build_uri(
        host : String? = nil,
        port : String? = nil,
        user : String? = nil,
        password : String? = nil,
        unix_socket : String? = nil,
        config_file : String? = nil,
        db : String? = nil,
      ) : String
        defs = option_file_defaults(config_file)

        socket = resolve_socket(unix_socket, host, defs)
        uri = build_base_uri(socket, host, port)

        # Real MySQL client libraries (what Ansible's own mysql_*
        # modules run on, via PyMySQL/mysqlclient), when no login_user:
        # is given at all, default the connection username to the
        # current OS user rather than leaving it empty - relevant here
        # specifically for login_unix_socket: connections (unix_socket
        # auth matches the connecting OS user against a MySQL account of
        # the same name; dev-sec mysql_hardening's own tasks all use
        # `login_unix_socket: ... | default(omit)` with no login_user:,
        # relying on exactly this to connect as the OS root user
        # krikri-playbook's own plugin process runs as). Previously left
        # uri.user completely unset when login_user: was omitted, which
        # authenticates as an empty-string username instead ("Access
        # denied for user ''@'localhost'") - not "no username", a
        # *different*, wrong username.
        uri.user = user || defs[:user] || ENV["USER"]? || "root"
        uri.password = password || defs[:password] if password || defs[:password]

        # The underlying mysql shard's own default (ssl-mode=preferred)
        # unconditionally attempts TLS whenever the server's handshake
        # capability flags claim SSL support - which a real MariaDB/MySQL
        # server does whenever it was *compiled* with OpenSSL, even if no
        # cert/key was ever configured and SSL is actually disabled
        # (have_ssl: DISABLED). Against exactly that (common, valid) server
        # config, "preferred" doesn't fall back to plaintext on failure (a
        # documented limitation of the vendored shard itself) - it just
        # crashes with a confusing "SSL_connect: ... wrong version number"
        # instead of connecting. There's no login_*/ssl_* param exposed for
        # TLS configuration anywhere in this codebase's mysql_db/mysql_user
        # plugins, so there's no way for a caller to opt out short of this -
        # explicitly disable it here instead.
        # SECURITY NOTE (deliberate, compatibility-preserving divergence):
        # Ansible's PyMySQL connection defaults to ssl-mode=preferred,
        # so mysql_* traffic is TLS when the server supports it. Here it is
        # always plaintext for TCP until the vendored shard grows working
        # TLS - known, documented, NOT fixed so behavior stays shippable.
        # The initial database (login_db) rides in the query string rather
        # than the URI path on purpose: for unix-socket connections the
        # shard reads the socket path FROM uri.path, so a `/dbname` path
        # component is only usable for TCP. The shard itself accepts a
        # `database` query param for both transports (Options.from_uri).
        # Found via an ad-hoc CLI comparison sweep against Ansible
        # (2026-09-13): mysql_query silently dropped login_db, so every
        # unqualified query failed with "No database selected".
        query_params = URI::Params.new
        query_params["ssl-mode"] = "disabled"
        query_params["database"] = db if db && !db.empty?
        uri.query = query_params.to_s

        uri.to_s
      end

      # Parses a MySQL option file (my.cnf-format) for the [client]
      # credentials relevant to a direct client-lib connection: user,
      # password, and socket. Returns all-nil when the file is absent,
      # unreadable, or has no [client] section - never raises. Comment and
      # quoting semantics follow Python's configparser as closely as a small
      # parser reasonably can (upstream uses configparser with
      # comment_prefixes ('#', ';', '!') so `!includedir` lines don't crash
      # parsing): '#', ';', and '!' start comments; '=' separates an
      # unquoted/quoted value; surrounding single/double quotes are stripped.
      private def self.comment_line?(line : String) : Bool
        line.empty? || line.starts_with?('#') || line.starts_with?(';') || line.starts_with?('!')
      end

      private def self.read_client_section(path : String) : Hash(String, String)
        client = {} of String => String
        in_client = false
        File.each_line(path) do |raw|
          line = raw.strip
          next if comment_line?(line)
          if line.starts_with?('[')
            section = line[1...-1].strip.downcase
            in_client = section == "client"
            next
          end
          next unless in_client
          equals = line.index('=')
          next unless equals
          key = line[0...equals].strip.downcase
          value = line[(equals + 1)..].strip
          client[key] = MysqlConnection.strip_quotes(value) unless key.empty?
        end
        client
      end

      def self.option_file_defaults(config_file : String?) : NamedTuple(user: String?, password: String?, socket: String?)
        empty = {user: nil, password: nil, socket: nil}
        return empty if config_file.nil? || config_file.empty?

        begin
          path = resolve_option_file_path(config_file)
          return empty if path.nil? || !File.exists?(path)

          client = read_client_section(path)
        rescue
          # An unreadable/malformed option file is treated as absent - never
          # fail a connection attempt over a config-file parse error.
          return empty
        end

        {user: client["user"]?, password: client["password"]?, socket: client["socket"]?}
      end

      # Resolves a config_file path to an absolute path, expanding a leading
      # `~` the same way Python's os.path.expanduser does (Ansible's
      # path-type params pass through that before any existence check).
      # Crystal's own File.expand_path does NOT expand `~` (it treats it as a
      # literal relative component), which is why this hand-rolls the tilde
      # expansion exactly like BasePlugin#expand_tilde does.
      def self.resolve_option_file_path(config_file : String) : String?
        path = config_file.strip
        return path unless path.starts_with?('~')

        rest = path[1..]
        username, _, remainder = rest.partition('/')
        home = if username.empty?
                 ENV["HOME"]? || System::User.find_by?(id: LibC.getuid.to_s).try(&.home_directory)
               else
                 System::User.find_by?(name: username).try(&.home_directory)
               end
        home ? File.join(home, remainder) : nil
      end

      def self.strip_quotes(value : String) : String
        if (value.starts_with?('"') && value.ends_with?('"')) || (value.starts_with?('\'') && value.ends_with?('\''))
          value[1...-1]
        else
          value
        end
      end
    end
  end
end

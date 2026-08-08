require "uri"

module CrystalPlay
  module PluginHelpers
    # MysqlConnection - pure logic for building a mysql:// connection URI
    # from Ansible-style login_* params. No I/O - mysql_db.cr/mysql_user.cr
    # do the actual DB.open.
    module MysqlConnection
      # unix_socket, given, takes precedence over host/port (matches real
      # Ansible's mysql_db/mysql_user own login_unix_socket precedence).
      def self.build_uri(
        host : String? = nil,
        port : String? = nil,
        user : String? = nil,
        password : String? = nil,
        unix_socket : String? = nil,
      ) : String
        uri = if unix_socket
                URI.new(scheme: "mysql", path: unix_socket)
              else
                URI.new(scheme: "mysql", host: host || "localhost", port: (port || "3306").to_i)
              end

        # Real MySQL client libraries (what real Ansible's own mysql_*
        # modules run on, via PyMySQL/mysqlclient), when no login_user:
        # is given at all, default the connection username to the
        # current OS user rather than leaving it empty - relevant here
        # specifically for login_unix_socket: connections (unix_socket
        # auth matches the connecting OS user against a MySQL account of
        # the same name; dev-sec mysql_hardening's own tasks all use
        # `login_unix_socket: ... | default(omit)` with no login_user:,
        # relying on exactly this to connect as the OS root user
        # crystal-ansible's own plugin process runs as). Previously left
        # uri.user completely unset when login_user: was omitted, which
        # authenticates as an empty-string username instead ("Access
        # denied for user ''@'localhost'") - not "no username", a
        # *different*, wrong username.
        uri.user = user || ENV["USER"]? || "root"
        uri.password = password if password

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
        uri.query = "ssl-mode=disabled"

        uri.to_s
      end
    end
  end
end

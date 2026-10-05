require "uri"

module Krikri
  module PluginHelpers
    # PostgresqlConnection - pure logic for building a postgres://
    # connection URI from Ansible-style login_* params. No I/O -
    # postgresql_db.cr/postgresql_user.cr do the actual DB.open.
    module PostgresqlConnection
      # unix_socket, given, takes precedence over host/port (matches
      # Ansible's postgresql_db/postgresql_user own login_unix_socket
      # precedence). crystal-pg expects a unix socket path via a "host"
      # query param, not the URI's own host component (verified against
      # its actual conninfo parsing source, not assumed) - the URI host
      # is left blank in that case.
      # Debian/Ubuntu's postgresql-common packaging (the target of every
      # real-host benchmark round so far) compiles libpq's default Unix
      # socket directory to this path - matches `postgresql.conf`'s own
      # `unix_socket_directories` default there.
      DEFAULT_UNIX_SOCKET_DIR = "/var/run/postgresql"

      private def self.new_uri(unix_socket : String?, host : String?, port : String?, path : String) : URI
        if unix_socket
          URI.new(scheme: "postgres", path: path)
        else
          URI.new(scheme: "postgres", host: host || "localhost", port: (port || "5432").to_i, path: path)
        end
      end

      def self.build_uri(
        host : String? = nil,
        port : String? = nil,
        user : String? = nil,
        password : String? = nil,
        unix_socket : String? = nil,
        dbname : String? = nil,
        sslmode : String? = nil,
      ) : String
        path = "/#{dbname || "postgres"}"

        # Real libpq (and psycopg2, which every postgresql_db/
        # postgresql_user real-Ansible run underneath actually uses)
        # defaults to a Unix socket connection - NOT TCP to "localhost"
        # - when no host: is given at all. Real bug found benchmarking
        # robertdebock.postgres (round 43): its own "Create postgres
        # database"/"Create postgres users" tasks never set login_host:,
        # relying on that Unix-socket-by-default behavior (peer auth,
        # matching the task's own become_user: postgres) - this plugin
        # instead always forced a TCP connection to "localhost", which
        # real pg_hba.conf gates behind `ident` (needs a running ident
        # daemon, absent here) rather than the `peer` auth a socket
        # connection gets, so it failed outright ("Could not connect to
        # the PostgreSQL server") while Ansible connected fine.
        unix_socket ||= DEFAULT_UNIX_SOCKET_DIR unless host

        uri = new_uri(unix_socket, host, port, path)

        uri.user = user if user
        uri.password = password if password

        params = URI::Params.new
        params["host"] = unix_socket if unix_socket
        # Only matters for the unix_socket branch (the URI's own `port`
        # already covers the TCP branch) - crystal-pg's socket-directory
        # lookup builds the actual socket filename as `.s.PGSQL.<port>`,
        # so a non-default port (e.g. robertdebock.postgres's own
        # `postgres_port: 6543`) needs to reach it via this query param
        # too, not just the URI's host:port pair.
        params["port"] = port if port && unix_socket
        params["sslmode"] = sslmode if sslmode
        uri.query = params.to_s unless params.to_s.empty?

        uri.to_s
      end

      # The connection target a params hash resolves to, for
      # diagnostics that have to name the server the plugin actually
      # dialed (libpq's connection-error text quotes the host/port or
      # the socket path verbatim). Applies the same defaults
      # #build_uri does: an absent host means a Unix socket in
      # DEFAULT_UNIX_SOCKET_DIR, an absent port means 5432.
      def self.effective_target(params : Hash(String, String)) : {host: String?, port: String, unix_socket: String?}
        login = resolve_login_params(params)
        host = login[:host]
        {
          host:        host,
          port:        login[:port] || "5432",
          unix_socket: login[:unix_socket] || (DEFAULT_UNIX_SOCKET_DIR unless host),
        }
      end

      # libpq's own connection-error wording, which is what real
      # (psycopg2 -> libpq) embeds in community.postgresql's
      # "unable to connect to database: %s" fail_json. Live-verified
      # against ansible-core 2.19.11 + community.postgresql 4.2.0
      # for every case reproduced below:
      #
      # - TCP, nothing listening (ECONNREFUSED):
      #     connection to server at "127.0.0.1", port 59999 failed: Connection refused\n
      #     \tIs the server running on that host and accepting TCP/IP connections?\n
      # - Unix socket, socket file/dir missing (ENOENT):
      #     connection to server on socket "/nonexistent/sockdir/.s.PGSQL.5432" failed: No such file or directory\n
      #     \tIs the server running locally and accepting connections on that socket?\n
      # - server answered and rejected us (its ErrorResponse carries
      #   the text, so the server-side severity is rebuilt as
      #   "<severity>:  <message>\n", and NO hint line follows):
      #     connection to server at "127.0.0.1", port 35433 failed: FATAL:  password authentication failed for user "postgres"\n
      #     connection to server at "127.0.0.1", port 35433 failed: FATAL:  database "nosuchdb" does not exist\n
      # - unresolvable host (libpq's own DNS wording, no hint line):
      #     could not translate host name "nosuchhost.invalid" to address: Name or service not known\n
      #
      # Reproducible vs not: the strerror text above is derived from
      # the exception CLASS Crystal raises (Socket::ConnectError is
      # raised only for ECONNREFUSED, Socket::Addrinfo::Error only for
      # a failed lookup) rather than from its message, because
      # Crystal's message for a refused connect misreports the errno
      # ("Resource temporarily unavailable"). What krikri CANNOT
      # reproduce: a temporary resolver failure, which libpq renders
      # with gai_strerror's "Temporary failure in name resolution"
      # (Crystal's Socket::Addrinfo::Error carries no gai code, so
      # krikri prints the EAI_NONAME wording instead), and any
      # strerror string from a non-glibc libc (libpq prints the
      # system's own, locale-dependent strings).
      def self.libpq_connect_error(ex : DB::ConnectionRefused, target : {host: String?, port: String, unix_socket: String?}) : String
        case cause = unwrap(ex.cause)
        when PQ::PQError
          # crystal-pg reports the server's ErrorResponse fields by
          # protocol-symbol name; the severity libpq prints ahead of
          # the message is :severity (a connect-time rejection is
          # always FATAL).
          severity = cause.field_message(:severity) || "FATAL"
          "#{target_prefix(target)} failed: #{severity}:  #{cause.message}\n"
        when Socket::Addrinfo::Error
          "could not translate host name \"#{target[:host]}\" to address: Name or service not known\n"
        when IO::Error
          "#{target_prefix(target)} failed: #{connect_strerror(cause, target)}\n\t#{hint(target)}\n"
        else
          "#{target_prefix(target)} failed: Connection refused\n\t#{hint(target)}\n"
        end
      end

      # crystal-pg wraps every connect-stage failure in a
      # PQ::ConnectionError whose cause is the socket-layer exception
      # that actually failed (or, for a server-side rejection, raises
      # PQ::PQError directly), so the diagnostic wants the innermost
      # exception - but only through PQ::ConnectionError, never
      # through a PQError's own chain.
      private def self.unwrap(ex : Exception?) : Exception?
        return nil unless ex
        return ex.cause if ex.is_a?(PQ::ConnectionError)
        ex
      end

      private def self.target_prefix(target : {host: String?, port: String, unix_socket: String?}) : String
        if unix_socket = target[:unix_socket]
          "connection to server on socket \"#{unix_socket}/.s.PGSQL.#{target[:port]}\""
        else
          "connection to server at \"#{target[:host]}\", port #{target[:port]}"
        end
      end

      private def self.hint(target : {host: String?, port: String, unix_socket: String?}) : String
        if target[:unix_socket]
          "Is the server running locally and accepting connections on that socket?"
        else
          "Is the server running on that host and accepting TCP/IP connections?"
        end
      end

      # strerror(3) text for the socket-layer failure Crystal reports,
      # as a plain string (libpq prints strerror's output verbatim).
      private def self.connect_strerror(cause : IO::Error, target : {host: String?, port: String, unix_socket: String?}) : String
        if cause.is_a?(Socket::ConnectError)
          if unix_socket = target[:unix_socket]
            # A missing socket directory is ENOENT; a present one with
            # no listening socket is ECONNREFUSED. Crystal raises
            # Socket::ConnectError for both, so the directory's
            # existence decides which one this was.
            if Dir.exists?(unix_socket)
              "Connection refused"
            else
              "No such file or directory"
            end
          else
            "Connection refused"
          end
        else
          cause.message || "Connection refused"
        end
      end

      # Resolves the login_host:/login_port:/login_user:/
      # login_unix_socket: params from a plugin's raw `@params`,
      # falling back to each one's real-Ansible deprecated alias
      # (`host:`/`port:`/`login:`/`unix_socket:` respectively -
      # `login_password:` has none) when the canonical `login_*` form
      # isn't set. Shared by postgresql_db.cr/postgresql_user.cr/
      # postgresql_privs.cr so the alias list only lives in one place.
      #
      # Real bug found benchmarking robertdebock.postgres (round 43):
      # its own "Create postgres users" task writes `port: "{{
      # postgres_port }}"` (the alias, for a non-default port like
      # 6543) - each plugin only ever read `login_port:`, so the
      # connection silently fell back to port 5432's Unix socket
      # instead, which doesn't exist on this host at all
      # (`DB::ConnectionRefused` / `PQ::ConnectionError: Cannot
      # establish connection`, confirmed via direct debug instrumentation
      # against a live host - the same URI, built by hand with the
      # correct port included, connected via `psql` immediately).
      def self.resolve_login_params(params : Hash(String, String)) : {host: String?, port: String?, user: String?, password: String?, unix_socket: String?}
        {
          host:        params["login_host"]? || params["host"]?,
          port:        params["login_port"]? || params["port"]?,
          user:        params["login_user"]? || params["login"]?,
          password:    params["login_password"]?,
          unix_socket: params["login_unix_socket"]? || params["unix_socket"]?,
        }
      end
    end
  end
end

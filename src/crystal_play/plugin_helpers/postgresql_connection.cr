require "uri"

module CrystalPlay
  module PluginHelpers
    # PostgresqlConnection - pure logic for building a postgres://
    # connection URI from Ansible-style login_* params. No I/O -
    # postgresql_db.cr/postgresql_user.cr do the actual DB.open.
    module PostgresqlConnection
      # unix_socket, given, takes precedence over host/port (matches real
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
        # the PostgreSQL server") while real Ansible connected fine.
        unix_socket ||= DEFAULT_UNIX_SOCKET_DIR unless host

        uri = if unix_socket
                URI.new(scheme: "postgres", path: path)
              else
                URI.new(scheme: "postgres", host: host || "localhost", port: (port || "5432").to_i, path: path)
              end

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

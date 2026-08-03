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

        uri = if unix_socket
                URI.new(scheme: "postgres", path: path)
              else
                URI.new(scheme: "postgres", host: host || "localhost", port: (port || "5432").to_i, path: path)
              end

        uri.user = user if user
        uri.password = password if password

        params = URI::Params.new
        params["host"] = unix_socket if unix_socket
        params["sslmode"] = sslmode if sslmode
        uri.query = params.to_s unless params.to_s.empty?

        uri.to_s
      end
    end
  end
end

require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # Shared PluginResult construction for the DB-family plugins'
    # connection/query failure rescues (mysql_*, postgresql_*). The
    # rescue CLAUSES must stay per-plugin (Crystal needs the concrete
    # exception type at each site: DB::ConnectionRefused, PQ::PQError,
    # MySql::Connection::PacketError), but the message shapes were
    # seven hand-copied pairs - a format tweak (adding rc, redacting a
    # URI) had to land seven times. One implementation now.
    module DbErrors
      # "Could not connect to the PostgreSQL server: ..." shape.
      def self.connection_failed(ex : DB::ConnectionRefused, server : String) : PluginResult
        PluginResult.new(changed: false, failed: true, msg: "Could not connect to the #{server} server: #{ex.message}")
      end

      # "PostgreSQL error: ..." / "MySQL error: ..." shape - for the
      # dialect's own query-error exception raised mid-session.
      def self.query_failed(ex : Exception, server : String) : PluginResult
        PluginResult.new(changed: false, failed: true, msg: "#{server} error: #{ex.message}")
      end
    end
  end
end

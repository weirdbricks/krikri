module Krikri
  module PluginHelpers
    # ansible.mysql's CommandResolver (module_utils/command_resolver.py): the
    # statement spelling a given server actually answers for a replication
    # read. MySQL renamed the SLAVE statements to REPLICA in 8.0.22 and the
    # MASTER ones to BINARY LOG in 8.2.0; MariaDB adopted its own spellings
    # in 10.5.1 / 10.5.2. The two disagree on SHOW SLAVE HOSTS: MySQL's
    # modern form is SHOW REPLICAS, MariaDB's is SHOW REPLICA HOSTS (it
    # rejects SHOW REPLICAS).
    module MysqlCommandResolver
      def self.resolve(command : String, implementation : String, version : String) : String
        mariadb = implementation.downcase == "mariadb"
        current = version_tuple(version)

        case command
        when "SHOW MASTER STATUS"
          if mariadb
            at_least?(current, 10, 5, 2) ? "SHOW BINLOG STATUS" : command
          else
            at_least?(current, 8, 2, 0) ? "SHOW BINARY LOG STATUS" : command
          end
        when "SHOW SLAVE STATUS"
          renamed?(current, mariadb) ? "SHOW REPLICA STATUS" : command
        when "SHOW SLAVE HOSTS"
          return command unless renamed?(current, mariadb)
          mariadb ? "SHOW REPLICA HOSTS" : "SHOW REPLICAS"
        else
          raise ArgumentError.new("Unsupported command: #{command}")
        end
      end

      private def self.renamed?(current : Array(Int32), mariadb : Bool) : Bool
        mariadb ? at_least?(current, 10, 5, 1) : at_least?(current, 8, 0, 22)
      end

      private def self.at_least?(current : Array(Int32), major : Int32, minor : Int32, patch : Int32) : Bool
        [major, minor, patch] <= current
      end

      private def self.version_tuple(version : String) : Array(Int32)
        parts = [] of Int32
        version.split(/[^0-9]+/).reject(&.empty?).first(3).each do |part|
          parts << (part.to_i32? || 0)
        end
        (parts + [0, 0, 0])[0, 3]
      end
    end
  end
end

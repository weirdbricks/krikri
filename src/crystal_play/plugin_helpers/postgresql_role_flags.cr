module CrystalPlay
  module PluginHelpers
    # PostgresqlRoleFlags - pure logic for parsing/rendering/comparing a
    # postgresql_user `role_attr_flags:` string. No I/O - postgresql_user.cr
    # does the actual CREATE/ALTER ROLE and pg_roles lookups.
    module PostgresqlRoleFlags
      FLAGS = %w[LOGIN CREATEDB CREATEROLE SUPERUSER INHERIT REPLICATION BYPASSRLS]

      # Parses "LOGIN,CREATEDB,NOSUPERUSER" (real Ansible's own
      # role_attr_flags: format) into {"LOGIN" => true, "CREATEDB" => true,
      # "SUPERUSER" => false}.
      def self.parse(spec : String) : Hash(String, Bool)
        flags = Hash(String, Bool).new

        spec.split(',').map(&.strip).reject(&.empty?).each do |token|
          upcased = token.upcase
          negated = upcased.starts_with?("NO")
          flag = negated ? upcased[2..] : upcased

          raise "unknown role attribute flag: #{token.inspect}" unless FLAGS.includes?(flag)
          flags[flag] = !negated
        end

        flags
      end

      # Renders {"LOGIN" => true, "SUPERUSER" => false} into
      # "LOGIN NOSUPERUSER" for a CREATE/ALTER ROLE statement.
      def self.to_sql(flags : Hash(String, Bool)) : String
        flags.map { |flag, value| value ? flag : "NO#{flag}" }.join(" ")
      end

      # The pg_roles column backing a given flag - verified against a real
      # PostgreSQL 17 server's pg_roles view.
      def self.column_for(flag : String) : String
        case flag
        when "LOGIN"       then "rolcanlogin"
        when "CREATEDB"    then "rolcreatedb"
        when "CREATEROLE"  then "rolcreaterole"
        when "SUPERUSER"   then "rolsuper"
        when "INHERIT"     then "rolinherit"
        when "REPLICATION" then "rolreplication"
        when "BYPASSRLS"   then "rolbypassrls"
        else                    raise "unknown role attribute flag: #{flag.inspect}"
        end
      end
    end
  end
end

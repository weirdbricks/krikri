module CrystalPlay
  module PluginHelpers
    # MysqlPrivileges - pure logic for parsing/comparing MySQL privilege
    # grants. No I/O - mysql_user.cr does the actual GRANT/REVOKE calls.
    module MysqlPrivileges
      record Grant, target : String, privileges : Set(String)

      # Parses a priv: param string in real Ansible's own format:
      # "db.table:PRIV1,PRIV2/db2.table2:PRIV3" (multiple grants separated
      # by "/", privileges within one grant separated by ",").
      def self.parse_spec(spec : String) : Array(Grant)
        spec.split('/').map { |entry| parse_entry(entry) }
      end

      private def self.parse_entry(entry : String) : Grant
        target, sep, privs = entry.partition(':')
        raise "invalid priv entry (expected db.table:priv1,priv2): #{entry.inspect}" if sep.empty?

        Grant.new(normalize_target(target.strip), normalize_privileges(privs.split(',')))
      end

      # Parses one line of real `SHOW GRANTS FOR user@host` output, e.g.
      # `GRANT SELECT, INSERT ON \`db\`.* TO \`user\`@\`host\``,
      # optionally suffixed `WITH GRANT OPTION` (mapped to a "GRANT"
      # pseudo-privilege, matching real Ansible's own priv: convention for
      # the grant option). Returns nil for the baseline
      # `GRANT USAGE ON *.* TO ... IDENTIFIED BY ...` identity row every
      # MySQL/MariaDB account has regardless of what's actually been
      # granted to it - not a real privilege grant, and would otherwise
      # always show up as a spurious diff against any desired priv: spec.
      def self.parse_show_grants_line(line : String) : Grant?
        match = line.match(/\AGRANT\s+(.+?)\s+ON\s+(\S+)\s+TO\s+/i)
        return nil unless match

        privileges = normalize_privileges(match[1].split(','))
        privileges << "GRANT" if line =~ /WITH GRANT OPTION/i

        return nil if privileges == Set{"USAGE"}

        Grant.new(normalize_target(match[2]), privileges)
      end

      # Reduces a full SHOW GRANTS result to the same {target => privileges}
      # shape parse_spec produces, for direct comparison.
      def self.current_grants(show_grants_lines : Enumerable(String)) : Hash(String, Set(String))
        grants = Hash(String, Set(String)).new
        show_grants_lines.each do |line|
          next unless grant = parse_show_grants_line(line)
          grants[grant.target] = grant.privileges
        end
        grants
      end

      def self.desired_grants(spec : String) : Hash(String, Set(String))
        parse_spec(spec).each_with_object(Hash(String, Set(String)).new) do |grant, hash|
          hash[grant.target] = grant.privileges
        end
      end

      private def self.normalize_privileges(raw : Enumerable(String)) : Set(String)
        raw.map(&.strip.upcase).reject(&.empty?).map { |p| p == "ALL PRIVILEGES" ? "ALL" : p }.to_set
      end

      private def self.normalize_target(raw : String) : String
        raw.gsub('`', "")
      end
    end
  end
end

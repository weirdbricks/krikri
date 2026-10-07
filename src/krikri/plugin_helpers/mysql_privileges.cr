module Krikri
  module PluginHelpers
    # MysqlPrivileges - pure logic for parsing/comparing MySQL privilege
    # grants. No I/O - mysql_user.cr does the actual GRANT/REVOKE calls.
    module MysqlPrivileges
      record Grant, target : String, privileges : Set(String)

      # One statement's worth of privilege change, produced by #plan_changes
      # and executed by mysql_user.cr. privileges carries the privilege
      # list for :revoke/:grant and is empty for :revoke_grant_option and
      # :revoke_all.
      record Op, kind : Symbol, target : String, privileges : Array(String)

      # Parses a priv: param string in Ansible's own format:
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
      # pseudo-privilege, matching Ansible's own priv: convention for
      # the grant option). The baseline `GRANT USAGE ON *.* TO ...`
      # identity row every MySQL/MariaDB account has is returned like
      # any other grant (as a {"USAGE"} privilege set): real
      # community.mysql keeps it too (privileges_get), and mysql_user's
      # idempotency comparison needs it - a desired spec of
      # "*.*:USAGE" must compare equal to the baseline row, not look
      # like a missing grant.
      def self.parse_show_grants_line(line : String) : Grant?
        match = line.match(/\AGRANT\s+(.+?)\s+ON\s+(\S+)\s+TO\s+/i)
        return nil unless match

        privileges = normalize_privileges(match[1].split(','))
        privileges << "GRANT" if line =~ /WITH GRANT OPTION/i

        Grant.new(normalize_target(match[2]), privileges)
      end

      # Reduces a full SHOW GRANTS result to the same {target => privileges}
      # shape parse_spec produces, for direct comparison. Multiple GRANT
      # lines for the same target (e.g. MySQL's static+dynamic privilege
      # split on *.*) are merged - mysql_info uses parse_show_grants_line
      # directly when it needs the per-line order instead.
      def self.current_grants(show_grants_lines : Enumerable(String)) : Hash(String, Set(String))
        grants = Hash(String, Set(String)).new
        show_grants_lines.each do |line|
          next unless grant = parse_show_grants_line(line)
          if existing = grants[grant.target]?
            grants[grant.target] = existing | grant.privileges
          else
            grants[grant.target] = grant.privileges
          end
        end
        grants
      end

      def self.desired_grants(spec : String) : Hash(String, Set(String))
        grants = parse_spec(spec).each_with_object(Hash(String, Set(String)).new) do |grant, hash|
          hash[grant.target] = grant.privileges
        end
        # The privilege USAGE stands for no privileges, so real's
        # privileges_unpack adds it on *.* when the spec doesn't mention
        # *.* at all (ensure_usage) - every account carries the baseline
        # USAGE row, and the comparison below needs both sides to carry it.
        grants["*.*"] = Set{"USAGE"} unless grants.has_key?("*.*")
        grants
      end

      # Plans the GRANT/REVOKE statements needed to bring an account's
      # current grants to the desired spec, the way real community.mysql
      # decides them (its user_add/user_mod privilege branch):
      # - targets granted today that the spec doesn't mention at all are
      #   revoked only when replacing (append_privs: false);
      # - on shared targets, append_privs only ever GRANTs the missing
      #   privileges and never revokes; replacing also revokes the extras;
      # - a grant of ALL makes revoking the leftovers pointless except the
      #   grant option (real's own shortcut);
      # - WITH GRANT OPTION cannot stand alone, so a grant of only the
      #   GRANT pseudo-privilege becomes USAGE + WITH GRANT OPTION.
      # Returns [] when the account already matches - mysql_user's
      # idempotency test is exactly "is the plan empty".
      def self.plan_changes(
        desired : Hash(String, Set(String)), current : Hash(String, Set(String)), append_privs : Bool,
      ) : Array(Op)
        ops = Array(Op).new

        unless append_privs
          (current.keys - desired.keys).sort!.each do |target|
            # GRANT OPTION is revoked first (real's privileges_revoke
            # order) and only when the account actually holds it -
            # MariaDB rejects a bare `REVOKE GRANT OPTION ON ...` with
            # "no such grant defined" (error 1141) otherwise.
            if current[target]?.try(&.includes?("GRANT"))
              ops << Op.new(:revoke_grant_option, target, [] of String)
            end
            ops << Op.new(:revoke_all, target, [] of String)
          end
        end

        desired.keys.sort!.each do |target|
          plan_target(ops, target, desired[target], current[target]?, append_privs)
        end

        ops
      end

      private def self.plan_target(
        ops : Array(Op), target : String, desired_privs : Set(String),
        current_privs : Set(String)?, append_privs : Bool,
      ) : Nil
        grant_privs = current_privs ? desired_privs - current_privs : desired_privs
        revoke_privs = append_privs || current_privs.nil? ? Set(String).new : current_privs - desired_privs
        if grant_privs.includes?("ALL")
          revoke_privs = revoke_privs & Set{"GRANT"}
        end
        grant_option = revoke_privs.includes?("GRANT") && !grant_privs.includes?("GRANT")

        ops << Op.new(:revoke_grant_option, target, [] of String) if grant_option

        revoked = revoke_privs.reject("GRANT").to_a.sort
        ops << Op.new(:revoke, target, revoked) unless revoked.empty? || (grant_option && revoked == ["USAGE"])

        grant_privs = grant_privs.add("USAGE") if grant_privs == Set{"GRANT"}
        granted = grant_privs.to_a.sort
        ops << Op.new(:grant, target, granted) unless granted.empty?
      end

      private def self.normalize_privileges(raw : Enumerable(String)) : Set(String)
        raw.map(&.strip.upcase).reject(&.empty?).map { |pth| pth == "ALL PRIVILEGES" ? "ALL" : pth }.to_set
      end

      private def self.normalize_target(raw : String) : String
        raw.gsub('`', "")
      end
    end
  end
end

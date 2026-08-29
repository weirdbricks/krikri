module CrystalPlay
  module PluginHelpers
    # UfwCommand - pure logic for building the `ufw` command line for a
    # rule/state/default/logging change. No I/O here - the plugin itself
    # runs the resulting command and interprets its output.
    #
    # Rule command shape verified against community.general's actual
    # ufw.py source (the "long format" documented directly in its own
    # comment): `ufw [route] [delete | insert NUM] allow|deny|reject|limit
    # [in|out on INTERFACE] [log] [from ADDRESS [port PORT]]
    # [to ADDRESS [port PORT]] [proto protocol] [app application]
    # [comment COMMENT]`.
    module UfwCommand
      def self.state_command(state : String) : String?
        case state
        when "enabled"  then "ufw --force enable"
        when "disabled" then "ufw disable"
        when "reloaded" then "ufw --force reload"
        when "reset"    then "ufw --force reset"
        else                 nil
        end
      end

      def self.logging_command(value : String) : String
        "ufw logging #{value}"
      end

      def self.default_command(value : String, direction : String?) : String
        parts = ["ufw", "default", value]
        parts << direction if direction
        parts.join(" ")
      end

      # params keys read: route, delete, insert, rule, direction,
      # interface, interface_in, interface_out, log, from_ip, from_port,
      # to_ip, to_port, proto, name, comment. `dry_run` inserts ufw's own
      # `--dry-run` flag right after the binary name, matching its real
      # position in the "long format" (`ufw [--dry-run] [route] ...`).
      def self.rule_command(params : Hash(String, String), dry_run : Bool = false) : String
        parts = ["ufw"]
        parts << "--dry-run" if dry_run
        parts << "route" if truthy?(params["route"]?)
        parts << "delete" if truthy?(params["delete"]?)

        if insert = params["insert"]?
          parts << "insert #{insert}" unless truthy?(params["delete"]?)
        end

        parts << params["rule"].to_s
        if direction = params["direction"]?
          parts << direction
        end
        append_interface(parts, params)
        parts << "log" if truthy?(params["log"]?)
        append_endpoints(parts, params)
        # Real Ansible checks these with `if p['proto']:`-style TRUTHINESS,
        # not presence: Oefenweb.ufw (round 196) maps missing item keys
        # via `default('')`, so the params carry empty STRINGS - appending
        # "port "/"proto "/"app ''" for those produced malformed commands
        # ("ERROR: Wrong number of arguments") where real ansible skipped
        # the clause entirely.
        parts << "proto #{params["proto"]}" if (v = params["proto"]?) && !v.empty?
        parts << "app '#{params["name"]}'" if (v = params["name"]?) && !v.empty?
        parts << "comment '#{params["comment"]}'" if (v = params["comment"]?) && !v.empty?

        parts.join(" ")
      end

      # from_ip/from_port/to_ip/to_port are four independent appends in
      # real Ansible's source (a plain list of (key, template) pairs each
      # checked on their own), not two ip+port pairs - a port given
      # without its matching ip still gets appended alone. Crucially,
      # from_ip/to_ip default to `'any'` in real Ansible's argument spec
      # (`from_ip=dict(..., default='any', ...)`), not unset/None - so
      # "from any"/"to any" is *always* emitted, even when the task only
      # gave a bare `to_port:`/`from_port:` with no ip at all. Omitting it
      # in that case (as this used to) produces a bare `ufw allow out
      # port 22 ...` that real `ufw` itself rejects with "ERROR: Need
      # 'to' or 'from' clause" - found running konstruktoid-hardening's
      # "Allow outgoing specified ports" task, which does exactly this.
      private def self.append_endpoints(parts : Array(String), params : Hash(String, String))
        # from_ip/to_ip are ALWAYS emitted (real Ansible's own argument
        # defaults are 'any', so "from any"/"to any" appear even for a
        # bare port rule - omitting them makes real ufw reject the
        # command with "Need 'to' or 'from' clause"). The PORTS are
        # truthiness-gated: empty strings coming from a role's
        # `default('')` mapping (Oefenweb.ufw, round 196) must not emit
        # a dangling "port " clause ("ERROR: Wrong number of arguments").
        parts << "from #{params["from_ip"]? || "any"}"
        parts << "port #{params["from_port"]}" if (v = params["from_port"]?) && !v.empty?
        parts << "to #{params["to_ip"]? || "any"}"
        parts << "port #{params["to_port"]}" if (v = params["to_port"]?) && !v.empty?
      end

      private def self.append_interface(parts : Array(String), params : Hash(String, String))
        if interface = params["interface"]?
          parts << "on #{interface}"
        elsif interface_in = params["interface_in"]?
          parts << "in on #{interface_in}"
        elsif interface_out = params["interface_out"]?
          parts << "out on #{interface_out}"
        end
      end

      private def self.truthy?(value : String?) : Bool
        return false unless value
        ["true", "yes", "1", "on"].includes?(value.downcase)
      end

      # Real ufw prints a line containing "Skipping" (e.g. "Skipping
      # adding existing rule") and exits 0 when a rule command is a
      # no-op - verified against community.general's actual ufw.py
      # source, which checks for exactly this substring
      # (`filter_line_that_contains("Skipping", rules_dry)`) to decide
      # `changed` in check mode. Used here as the changed signal for a
      # real (non-dry-run) application too, since replicating ufw's full
      # rule-tuple diffing logic would need actually-working netfilter
      # access to verify - not available in this project's Docker-based
      # compat harness (rootless podman container), so this is
      # source-verified but not further behavior-verified end-to-end the
      # way every other plugin in this codebase has been.
      def self.changed_from_output?(output : String) : Bool
        !output.includes?("Skipping")
      end

      # Resolves `insert:`/`insert_relative_to:` into the actual absolute
      # `ufw insert NUM` position, given `ufw status numbered`'s own
      # output. `zero` (the default) is a pure passthrough - the caller
      # only needs this for the other four values. Algorithm (including
      # the "no ipv4/ipv6 rules yet" fallback positions and the
      # insert-past-the-end-means-no-insert-flag-at-all case) copied
      # field-for-field from community.general's actual ufw.py source,
      # not derived from the docs' prose - it's the one piece of this
      # plugin dense enough that reproducing it from the English
      # description alone would very likely have drifted from the real
      # rule-number arithmetic.
      #
      # Returns nil if the resolved position would fall past the last
      # existing rule - real ufw rejects an insert number larger than the
      # maximum rule number, so real Ansible drops the `insert` flag
      # entirely in that case (the rule is just appended normally)
      # instead of sending a command ufw would refuse.
      def self.resolve_insert(insert : Int32, relative_to_cmd : String, numbered_status : String) : Int32?
        return insert if relative_to_cmd == "zero"

        lines = numbered_lines(numbered_status)
        last_number = lines.max_of?(&.[0]) || 0
        insert_to = insert + relative_to(relative_to_cmd, lines, last_number)
        insert_to > last_number ? nil : insert_to
      end

      private def self.numbered_lines(numbered_status : String) : Array({Int32, Bool})
        line_re = /^\[\s*(\d+)\]\s/
        numbered_status.lines.compact_map do |line|
          next unless match = line.match(line_re)
          {match[1].to_i, line.includes?("(v6)")}
        end
      end

      private def self.relative_to(relative_to_cmd : String, lines : Array({Int32, Bool}), last_number : Int32) : Int32
        max_ipv4 = lines.select { |(_, ipv6)| !ipv6 }.max_of?(&.[0])
        has_ipv6 = lines.any? { |(_, ipv6)| ipv6 }

        case relative_to_cmd
        when "first-ipv4" then 1
        when "last-ipv4"  then max_ipv4 || 1
        when "first-ipv6" then max_ipv4 ? max_ipv4 + 1 : 1
        when "last-ipv6"  then has_ipv6 ? last_number : last_number + 1
        else                   0
        end
      end
    end
  end
end

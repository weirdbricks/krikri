require "json"
require "../shell"

module Krikri
  module PluginHelpers
    # Pure rule-construction/command-building/validation logic for
    # `plugins/iptables.cr`, split out so it can be unit-tested without a
    # real `iptables` binary/root (`-C`/`-A`/`-D` all require
    # CAP_NET_ADMIN, unavailable in the spec sandbox - see
    # `plugins/iptables.cr`'s own doc comment). Mirrors Ansible's
    # `construct_rule()` flag-for-flag, including its exact ordering
    # (matters for `-C` to actually match what `-A` would insert), its
    # `push_arguments()` command framing (rule_num only on `-I`, `-w`
    # after the action, `--numeric` only on the `-L` call sites), and its
    # argument-spec validation messages (mutually_exclusive /
    # required_if / required_by wording from
    # the Ansible module).
    #
    # `construct_rule()` returns RAW tokens, exactly like Ansible's own:
    # values as given, no quoting - the registered `rule` string is
    # Ansible's `' '.join(construct_rule(params))` (probe-verified:
    # a comment value reaches it unquoted, words joined with plain
    # spaces). Quoting exists only when the exec command string is
    # built (`push_arguments` shell-quotes each token so the
    # /bin/bash -c framing keeps every value ONE argument, the way
    # Ansible's run_command passes its argv list); `push_arguments`
    # with `for_display: true` returns the raw space-join that
    # Ansible's `_clean_args` puts in a failure's `cmd`.
    module IptablesCommand
      # Real-Ansible parameter order, flag-for-flag (construct_rule()).
      # Returns the flag list, or a real-Ansible failure message when
      # building it raises the way Python does - see the two quirks
      # noted inline below.
      def self.construct_rule(params : Hash(String, String)) : Array(String) | String
        # Real quirk 1: `tcp_flags` given as a dict without both
        # `flags` and `flags_set` still passes the module's own
        # `'flags' in param and 'flags_set' in param` guard (the
        # argspec fills both suboptions with None), and then
        # `','.join(param['flags'])` raises "can only join an
        # iterable". Verified live against ansible-core 2.19.11 -
        # krikri silently dropped the flag instead.
        if raw = params["tcp_flags"]?
          parsed = JSON.parse(raw) rescue nil
          if parsed
            flags = parsed["flags"]?
            flags_set = parsed["flags_set"]?
            return "can only join an iterable" if flags.nil? || flags_set.nil?
          end
        end

        rule = [] of String
        append_param(rule, params["protocol"]?, "-p")
        append_param(rule, params["source"]?, "-s")
        append_param(rule, params["destination"]?, "-d")
        # Real bug found benchmarking bitintheskud.ansible-role-ecs-agent's
        # own `match: tcp` rule: this was "-mat" (a typo) instead of the
        # actual iptables flag "-m" - GNU iptables' getopt_long_only
        # parses a bare "-mat" as "-m" with its value glued on ("at"),
        # tries to load a nonexistent netfilter match extension named
        # "at", and errors ("Couldn't load match `at'") on BOTH the `-C`
        # existence check and the `-A` apply - silently, since
        # `apply_rule` doesn't check `remote_exec`'s exit code, so the
        # failed `-A` was misreported as `changed: true`/"Rule applied"
        # and the real NAT rule was never actually created. `-C` then
        # failed the same way on every subsequent run, so `-A` (and the
        # false "changed") repeated forever - never converging, and
        # never functionally applying the redirect rule the role needs.
        each_csv(params["match"]?) { |mat| append_param(rule, mat, "-m") }
        append_tcp_flags(rule, params["tcp_flags"]?)
        append_param(rule, params["jump"]?, "-j")
        if (jump = params["jump"]?) && jump.downcase == "tee"
          append_param(rule, params["gateway"]?, "--gateway")
        end
        append_param(rule, params["log_prefix"]?, "--log-prefix")
        append_param(rule, params["log_level"]?, "--log-level")
        append_param(rule, params["to_destination"]?, "--to-destination")
        if dports = params["destination_ports"]?
          unless dports.empty?
            rule.concat(["-m", "multiport"])
            rule.concat(["--dports", dports])
          end
        end
        append_param(rule, params["to_source"]?, "--to-source")
        append_param(rule, params["goto"]?, "-g")
        append_param(rule, params["in_interface"]?, "-i")
        append_param(rule, params["out_interface"]?, "-o")
        append_param(rule, params["fragment"]?, "-f")
        append_param(rule, params["set_counters"]?, "-c")
        append_param(rule, params["source_port"]?, "--source-port")
        append_param(rule, params["destination_port"]?, "--destination-port")
        append_param(rule, params["to_ports"]?, "--to-ports")
        append_param(rule, params["set_dscp_mark"]?, "--set-dscp")
        if (mark = params["set_dscp_mark"]?) && !mark.empty? &&
           (jump = params["jump"]?) && jump.downcase != "dscp"
          rule.concat(["-j", "DSCP"])
        end
        append_param(rule, params["set_dscp_mark_class"]?, "--set-dscp-class")
        if (mark_class = params["set_dscp_mark_class"]?) && !mark_class.empty? &&
           (jump = params["jump"]?) && jump.downcase != "dscp"
          rule.concat(["-j", "DSCP"])
        end
        append_syn(rule, params["syn"]?)
        if ctstate = params["ctstate"]?
          append_ctstate(rule, ctstate, match_tokens(params))
        end
        src_range = params["src_range"]?
        dst_range = params["dst_range"]?
        if src_range || dst_range
          unless match_tokens(params).includes?("iprange")
            rule.concat(["-m", "iprange"])
          end
          append_param(rule, src_range, "--src-range")
          append_param(rule, dst_range, "--dst-range")
        end
        if match_set = params["match_set"]?
          if match_tokens(params).includes?("set")
            append_param(rule, match_set, "--match-set")
            note_match_set_flags(rule, params)
          else
            rule.concat(["-m", "set"])
            append_param(rule, match_set, "--match-set")
            note_match_set_flags(rule, params)
          end
        end
        if (params["limit"]? && !params["limit"].empty?) ||
           (params["limit_burst"]? && !params["limit_burst"].empty?)
          rule.concat(["-m", "limit"])
        end
        append_param(rule, params["limit"]?, "--limit")
        append_param(rule, params["limit_burst"]?, "--limit-burst")
        if uid = params["uid_owner"]?
          rule.concat(["-m", "owner"])
          append_param(rule, uid, "--uid-owner")
        end
        if gid = params["gid_owner"]?
          rule.concat(["-m", "owner"])
          append_param(rule, gid, "--gid-owner")
        end
        if params["jump"]?.nil?
          append_jump(rule, params["reject_with"]?, "REJECT")
          append_jump(rule, params["set_dscp_mark_class"]?, "DSCP")
          append_jump(rule, params["set_dscp_mark"]?, "DSCP")
        end
        append_param(rule, params["reject_with"]?, "--reject-with")
        if params["ip_version"]? == "both" && (icmp = params["icmp_type"]?)
          # Ansible's ICMP_TYPE_OPTIONS["both"] is the single flag
          # string "--icmp-type --icmpv6-type" followed by the one value -
          # i.e. both flags share the one value, on both binaries'
          # identical rule string.
          rule.concat(["--icmp-type", "--icmpv6-type", icmp])
        else
          icmp_flag = (params["ip_version"]? == "ipv6") ? "--icmpv6-type" : "--icmp-type"
          append_param(rule, params["icmp_type"]?, icmp_flag)
        end
        if comment = params["comment"]?
          rule.concat(["-m", "comment", "--comment", comment])
        end

        # Real quirk 2: `match_set` without `match_set_flags` appends
        # Ansible's None into the rule list (append_match_flag takes the
        # flag value unconditionally), so the module's own
        # `rule=' '.join(construct_rule(...))` raises with the index of
        # that None. Verified live against ansible-core 2.19.11.
        if none_at = rule.index(NONE_PLACEHOLDER)
          return "sequence item #{none_at}: expected str instance, NoneType found"
        end

        rule
      end

      # Stand-in for the None real appends for a missing
      # match_set_flags; replaced by the failure message before
      # construct_rule ever returns a list.
      private NONE_PLACEHOLDER = "\u0000krikri-iptables-none\u0000"

      private def self.note_match_set_flags(rule : Array(String), params : Hash(String, String)) : Nil
        if flags = params["match_set_flags"]?
          rule << flags
        else
          rule << NONE_PLACEHOLDER
        end
      end

      # Ansible's push_arguments(): everything it builds (the `-C`
      # check, `-A`/`-I`/`-D` applies, the `-F`/`-P`/`-L`/`-N`/`-X`
      # chain/policy operations) shares this framing - `-t table`,
      # action, chain, the insert position (only on `-I`), then `-w`
      # wait, then the rule flags. `numeric` is appended only by the
      # `-L` call sites (get_chain_policy/check_chain_present).
      #
      # The rule tokens arrive RAW (see construct_rule); the exec
      # string shell-quotes each one with `Shell.quote_arg` - unlike
      # `quote_if_needed` it treats whitespace as unsafe, so a
      # multi-word value (comment, set_counters "10 20") stays ONE
      # argument, matching Ansible's run_command argv list (which
      # passes each value as a single element, whatever it contains).
      # With `for_display` the raw tokens are space-joined instead,
      # byte-identical to Ansible's `' '.join(...)` rule string and
      # `_clean_args` failure cmd.
      def self.push_arguments(bin : String, action : String, chain : String?, table : String,
                              rule : Array(String) = [] of String, rule_num : String? = nil,
                              wait : String? = nil, numeric : Bool = false,
                              for_display : Bool = false) : String
        parts = [bin, "-t", table, action]
        parts << chain if chain
        parts << rule_num if action == "-I" && rule_num && !rule_num.empty?
        parts.concat(["-w", wait]) if wait && !wait.empty?
        parts.concat(rule)
        parts << "--numeric" if numeric
        parts.map { |part| for_display ? part : Shell.quote_arg(part) }.join(" ")
      end

      # Ansible's argument-spec validation for this module,
      # message-for-message (the Ansible module wording),
      # in its own evaluation order: mutually_exclusive (which
      # Ansible checks BEFORE applying defaults, so only an explicitly
      # passed flush: counts), then the per-parameter choices, then
      # required_if, then required_by. Returns the failure message, or
      # nil when everything passes.
      #
      # CHOICES_BY_PARAM: the argument_spec's own choices lists, in the
      # module's declaration order (the failure message echoes that
      # order). Real-Ansible position pinned empirically: a
      # mutually-exclusive pair fires before choices (flush +
      # policy=DENY reports the mutual exclusion), but choices fire
      # before required_if (state=enabled with no chain reports the
      # choice, not the missing chain).
      CHOICES_BY_PARAM = {
        "table"           => ["filter", "nat", "mangle", "raw", "security"],
        "state"           => ["absent", "present"],
        "action"          => ["append", "insert"],
        "ip_version"      => ["ipv4", "ipv6", "both"],
        "syn"             => ["ignore", "match", "negate"],
        "policy"          => ["ACCEPT", "DROP", "QUEUE", "RETURN"],
        "match_set_flags" => ["src", "dst", "src,dst", "dst,src", "src,src", "dst,dst"],
        "log_level"       => ["0", "1", "2", "3", "4", "5", "6", "7", "emerg", "alert", "crit", "error", "warning", "notice", "info", "debug"],
      }

      def self.validate(params : Hash(String, String)) : String?
        if params.has_key?("flush") && params["policy"]?
          return "parameters are mutually exclusive: flush|policy"
        end
        if params["set_dscp_mark"]? && params["set_dscp_mark_class"]?
          return "parameters are mutually exclusive: set_dscp_mark|set_dscp_mark_class"
        end

        CHOICES_BY_PARAM.each do |name, allowed|
          value = params[name]?
          next if value.nil? || value.empty? || allowed.includes?(value)
          return "value of #{name} must be one of: #{allowed.join(", ")}, got: #{value}"
        end

        if jump = params["jump"]?
          if (jump == "TEE" || jump == "tee") && !params["gateway"]?
            return "jump is #{jump} but all of the following are missing: gateway"
          end
        end
        # flush defaults to False, so this fires whenever chain is
        # absent and flush is not truthy - including a policy: task
        # without a chain (Ansible fails that the same way).
        flush = params["flush"]?
        flush_true = flush ? ["true", "yes", "1", "on", "y", "t"].includes?(flush.downcase) : false
        unless flush_true
          return "flush is False but all of the following are missing: chain" unless params["chain"]?
        end

        if params["set_dscp_mark"]? && params["jump"]?.nil?
          return "missing parameter(s) required by 'set_dscp_mark': jump"
        end
        if params["set_dscp_mark_class"]? && params["jump"]?.nil?
          return "missing parameter(s) required by 'set_dscp_mark_class': jump"
        end

        nil
      end

      private def self.append_syn(rule : Array(String), syn : String?) : Nil
        if syn == "match"
          rule << "--syn"
        elsif syn == "negate"
          rule.concat(["!", "--syn"])
        end
      end

      private def self.append_ctstate(rule : Array(String), ctstate : String, matches : Array(String)) : Nil
        if matches.includes?("conntrack")
          rule.concat(["--ctstate", ctstate])
        elsif matches.includes?("state")
          rule.concat(["--state", ctstate])
        else
          rule.concat(["-m", "conntrack", "--ctstate", ctstate])
        end
      end

      private def self.append_jump(rule : Array(String), value : String?, jump : String) : Nil
        return unless value
        rule.concat(["-j", jump])
      end

      private def self.append_param(rule : Array(String), value : String?, flag : String) : Nil
        return unless value
        if value.starts_with?('!')
          rule.concat(["!", flag, value[1..]])
        else
          rule.concat([flag, value])
        end
      end

      # append_tcp_flags(): both keys must be present (Ansible
      # silently skips the flag otherwise); list values arrive
      # JSON-encoded (the engine's dict-param stringification) and get
      # comma-joined like Python's ','.join().
      private def self.append_tcp_flags(rule : Array(String), raw : String?) : Nil
        return unless raw
        parsed = JSON.parse(raw) rescue return
        flags = parsed["flags"]?
        flags_set = parsed["flags_set"]?
        return unless flags && flags_set
        rule.concat(["--tcp-flags", csv_join(flags), csv_join(flags_set)])
      end

      private def self.csv_join(node : JSON::Any) : String
        if arr = node.as_a?
          arr.map { |item| item.as_s? || item.to_s }.join(",")
        else
          node.as_s? || node.to_s
        end
      end

      # `match:` as a list of exact tokens (Ansible's
      # `'conntrack' in params['match']` membership tests are token
      # equality, not substring tests).
      private def self.match_tokens(params : Hash(String, String)) : Array(String)
        raw = params["match"]?
        return [] of String unless raw
        raw.split(',').map(&.strip).reject(&.empty?)
      end

      private def self.each_csv(value : String?, &) : Nil
        return unless value
        value.split(',').each { |v| yield v.strip unless v.strip.empty? }
      end
    end
  end
end

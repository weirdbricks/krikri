#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/iptables_command"

module CrystalPlay
  # Iptables plugin - manages a single netfilter rule/chain/policy.
  # Compatible with Ansible's ansible.builtin.iptables module.
  #
  # Idempotency and apply both shell straight to the real `iptables`/
  # `ip6tables` binary, mirroring the real module exactly: `-C` (check)
  # to test whether a rule is already present, `-A`/`-I` to add it,
  # `-D` to remove it - real Ansible's own module works the same way
  # (no netlink/library binding, just CLI wrapping), so this matches it
  # rule-construction-flag-for-flag rather than reimplementing netfilter
  # semantics.
  #
  # Scope-cut (matching this codebase's usual practice of covering the
  # common real-world shape rather than every flag - see `firewalld.cr`'s
  # own doc comment for the same trade-off): NOT implemented -
  # `tcp_flags`, `gateway`/`jump: TEE`, `goto`, `set_dscp_mark(_class)`,
  # `src_range`/`dst_range`, `match_set(_flags)`, `uid_owner`/
  # `gid_owner`, `wait`, `numeric`. These are all real, documented
  # module params but rare in practice (no benchmark role touched any of
  # them, including robertdebock.natrouter's `-t nat -A POSTROUTING -o
  # <if> -s <net> -d <dest> -p <proto> -j MASQUERADE -m comment --comment
  # ...` shape, which IS covered).
  class IptablesPlugin < BasePlugin
    def execute : PluginResult
      check_mode = true?(@params["check_mode"]?)
      ip_version = @params["ip_version"]? || "ipv4"
      binaries = ip_version == "both" ? ["iptables", "ip6tables"] : [ip_version == "ipv6" ? "ip6tables" : "iptables"]

      flush = true?(@params["flush"]?)
      policy = @params["policy"]?
      chain = @params["chain"]?
      chain_management = true?(@params["chain_management"]?)
      state = @params["state"]? || "present"
      rule_flags = PluginHelpers::IptablesCommand.construct_rule(@params)

      any_changed = false
      msgs = [] of String

      binaries.each do |bin|
        if flush
          any_changed = true
          remote_exec("#{bin} -t #{table} -F #{chain}") unless check_mode
          msgs << "flushed #{chain}"
        elsif policy
          current = current_policy(bin, chain)
          if current != policy
            any_changed = true
            remote_exec("#{bin} -t #{table} -P #{chain} #{policy}") unless check_mode
          end
          msgs << "policy #{policy}"
        elsif chain && rule_flags.empty?
          present = chain_present?(bin, chain)
          if state == "absent"
            if present
              any_changed = true
              remote_exec("#{bin} -t #{table} -X #{chain}") if chain_management && !check_mode
            end
          else
            unless present
              any_changed = true
              remote_exec("#{bin} -t #{table} -N #{chain}") if chain_management && !check_mode
            end
          end
        else
          return missing_param("chain") unless chain
          present = rule_present?(bin, chain, rule_flags)
          should_be_present = state == "present"
          if present != should_be_present
            any_changed = true
            unless check_mode
              action = @params["action"]? == "insert" ? "-I" : "-A"
              action = "-D" unless should_be_present
              remote_exec("#{bin} -t #{table} #{action} #{chain} #{rule_flags.join(" ")}")
            end
          end
        end
      end

      PluginResult.new(
        changed: any_changed,
        failed: false,
        msg: any_changed ? "Rule applied" : "Rule already in desired state"
      )
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    private def table : String
      @params["table"]? || "filter"
    end

    private def current_policy(bin : String, chain : String?) : String?
      result = remote_exec("#{bin} -t #{table} -L #{chain} 2>/dev/null")
      header = result[:stdout].split("\n").first?
      return nil unless header
      if m = header.match(/\(policy ([A-Z]+)\)/)
        m[1]
      end
    end

    private def chain_present?(bin : String, chain : String?) : Bool
      result = remote_exec("#{bin} -t #{table} -L #{chain} > /dev/null 2>&1")
      result[:exit_code] == 0
    end

    private def rule_present?(bin : String, chain : String, rule_flags : Array(String)) : Bool
      result = remote_exec("#{bin} -t #{table} -C #{chain} #{rule_flags.join(" ")} > /dev/null 2>&1")
      result[:exit_code] == 0
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::IptablesPlugin.new(config)
plugin.run

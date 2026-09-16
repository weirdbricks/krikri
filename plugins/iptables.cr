#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/iptables_command"

module Krikri
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
  # All parameter flags, the command framing (rule_num only on `-I`,
  # `-w wait` on every operation, `--numeric` on the `-L` probes) and
  # the argument-spec validations (mutually_exclusive / required_if /
  # required_by, including real Ansible's exact failure messages) live
  # in `PluginHelpers::IptablesCommand`, mirroring the real module's
  # `construct_rule()`/`push_arguments()`/argument_spec.
  #
  # Scope-cut (matching this codebase's usual practice of covering the
  # common real-world shape rather than every flag - see `firewalld.cr`'s
  # own doc comment for the same trade-off): `wait` is passed through
  # verbatim without real Ansible's iptables-version gating (it drops
  # `-w` entirely below iptables 1.4.20 and seconds support below 1.6.0;
  # every current distro ships >= 1.6.0).
  class IptablesPlugin < BasePlugin
    @failure : String?

    def execute : PluginResult
      check_mode = true?(@params["_ansible_check_mode"]?)
      ip_version = @params["ip_version"]? || "ipv4"
      binaries = ip_version == "both" ? ["iptables", "ip6tables"] : [ip_version == "ipv6" ? "ip6tables" : "iptables"]

      flush = true?(@params["flush"]?)
      policy = @params["policy"]?
      chain = @params["chain"]?
      chain_management = true?(@params["chain_management"]?)
      state = @params["state"]? || "present"

      # Real Ansible's argument-spec validation (mutually_exclusive /
      # required_if / required_by), with its own failure messages.
      if err = PluginHelpers::IptablesCommand.validate(@params)
        return PluginResult.new(changed: false, failed: true, msg: err)
      end

      # Real Ansible's log-jump enforcement: logging options force
      # jump=LOG when unset and fail with any other jump target.
      if @params["log_prefix"]? || @params["log_level"]?
        jump = @params["jump"]?
        if jump.nil?
          @params["jump"] = "LOG"
        elsif jump != "LOG"
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Logging options can only be used with the LOG jump target."
          )
        end
      end

      rule_flags = PluginHelpers::IptablesCommand.construct_rule(@params)

      msgs = [] of String

      any_changed = binaries.reduce(false) do |changed, bin|
        changed | apply_for_bin(bin, flush, policy, chain, rule_flags, state, chain_management, check_mode, msgs)
      end

      if failure = @failure
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: failure
        )
      end

      PluginResult.new(
        changed: any_changed,
        failed: false,
        msg: any_changed ? "Rule applied" : "Rule already in desired state"
      )
    end

    private def apply_for_bin(bin : String, flush : Bool, policy : String?, chain : String?,
                              rule_flags : Array(String), state : String, chain_management : Bool,
                              check_mode : Bool, msgs : Array(String)) : Bool
      if flush
        apply_flush(bin, chain, check_mode, msgs)
        true
      elsif pol = policy
        apply_policy(bin, chain, pol, check_mode, msgs)
      elsif chain && rule_flags.empty?
        apply_chain_state(bin, chain, state, chain_management, check_mode)
      else
        return false unless c = chain
        apply_rule(bin, c, rule_flags, state, check_mode)
      end
    end

    private def apply_flush(bin : String, chain : String?, check_mode : Bool, msgs : Array(String)) : Nil
      unless check_mode
        fail_on_command_failure(remote_exec(push(bin, "-F", chain)))
      end
      msgs << "flushed #{chain}"
    end

    private def apply_policy(bin : String, chain : String?, policy : String, check_mode : Bool, msgs : Array(String)) : Bool
      current = current_policy(bin, chain)
      if current.nil?
        # Real Ansible fails here rather than guessing.
        @failure = "Can't detect current policy"
        return false
      end
      changed = current != policy
      if changed && !check_mode
        fail_on_command_failure(remote_exec("#{push(bin, "-P", chain)} #{policy}"))
      end
      msgs << "policy #{policy}"
      changed
    end

    private def apply_chain_state(bin : String, chain : String?, state : String, chain_management : Bool, check_mode : Bool) : Bool
      present = chain_present?(bin, chain)
      changed = state == "absent" ? present : !present
      if changed
        action = state == "absent" ? "-X" : "-N"
        fail_on_command_failure(remote_exec(push(bin, action, chain))) if chain_management && !check_mode
      end
      changed
    end

    private def apply_rule(bin : String, chain : String, rule_flags : Array(String), state : String, check_mode : Bool) : Bool
      present = rule_present?(bin, chain, rule_flags)
      should_be_present = state == "present"
      return false if present == should_be_present

      return true if check_mode
      action = should_be_present ? (@params["action"]? == "insert" ? "-I" : "-A") : "-D"
      fail_on_command_failure(remote_exec(push(bin, action, chain, rule: rule_flags)))
      true
    end

    # Real Ansible runs every mutating operation (the -F/-P/-N/-X/-A/-I/-D
    # call sites) through module.run_command(check_rc=True) - a non-zero
    # exit from the real iptables/ip6tables binary fails the task with
    # the binary's stderr as the message. It is never swallowed into a
    # silent "changed: true" (an -A on a nonexistent chain used to be
    # reported exactly that way). First failure wins: a later operation
    # never overwrites an already-recorded failure.
    private def fail_on_command_failure(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : Nil
      return if result[:exit_code] == 0 || @failure
      @failure = [result[:stderr].strip, result[:stdout].strip]
        .reject(&.empty?)
        .first?
      @failure ||= "Failure executing command, exit code: #{result[:exit_code]}"
    end

    # Real Ansible's push_arguments(): one shared command framing for
    # every operation this plugin runs, including `-w wait` (when set)
    # and the `-I`-only insert position.
    private def push(bin : String, action : String, chain : String? = nil,
                     rule : Array(String) = [] of String, numeric : Bool = false) : String
      PluginHelpers::IptablesCommand.push_arguments(
        bin, action, chain, table,
        rule: rule,
        rule_num: @params["rule_num"]?,
        wait: @params["wait"]?,
        numeric: numeric
      )
    end

    private def table : String
      @params["table"]? || "filter"
    end

    private def current_policy(bin : String, chain : String?) : String?
      result = remote_exec("#{push(bin, "-L", chain, numeric: true?(@params["numeric"]?))} 2>/dev/null")
      header = result[:stdout].split("\n").first?
      return nil unless header
      if m = header.match(/\(policy ([A-Z]+)\)/)
        m[1]
      end
    end

    private def chain_present?(bin : String, chain : String?) : Bool
      result = remote_exec("#{push(bin, "-L", chain, numeric: true?(@params["numeric"]?))} > /dev/null 2>&1")
      result[:exit_code] == 0
    end

    private def rule_present?(bin : String, chain : String, rule_flags : Array(String)) : Bool
      result = remote_exec("#{push(bin, "-C", chain, rule: rule_flags)} > /dev/null 2>&1")
      result[:exit_code] == 0
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::IptablesPlugin.new(config)
plugin.run

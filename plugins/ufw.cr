#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/ufw_command"

module CrystalPlay
  # Ufw plugin - manages the Uncomplicated Firewall. Compatible with
  # Ansible's ufw module - registered here as community.general.ufw,
  # matching its real FQCN (verified via `ansible-doc ufw`; it lives in
  # the separate community.general collection, not ansible-core).
  #
  # Supported parameters:
  # - state: enabled | disabled | reloaded | reset
  # - logging: on/off/low/medium/high/full
  # - default: allow | deny | reject (with optional `direction:`)
  # - rule: allow | deny | reject | limit, plus direction/interface/
  #   interface_in/interface_out/log/from_ip/from_port/to_ip/to_port/
  #   proto/name (app profile)/comment/delete/insert/route - command
  #   shape verified against community.general's actual ufw.py source
  #   (see `src/crystal_play/plugin_helpers/ufw_command.cr`)
  # - check_mode: run with `--dry-run` instead of applying for real
  #
  # `ufw` itself refuses to run at all without root - even a bare
  # `ufw status` fails with "ERROR: You need to be root to run this
  # script" - so, unlike every other plugin added in this phase, this one
  # could not be verified end-to-end against real ansible-playbook via
  # the compat harness: the harness's container lacks working netfilter
  # access even running as root (confirmed: `ufw status` fails inside it
  # with an iptables permission error unrelated to ufw itself). The
  # command-construction logic is verified against real Ansible's actual
  # source, and the "Skipping" idempotency signal is the literal
  # substring real ufw's own module checks for - but the actual firewall
  # behavior has not been confirmed against a real, working ufw
  # installation the way every other plugin in this codebase has been.
  #
  # `insert_relative_to` (`zero` default / `first-ipv4` / `last-ipv4` /
  # `first-ipv6` / `last-ipv6`) resolves the actual `ufw insert NUM`
  # position by first running `ufw status numbered` and parsing it - see
  # `PluginHelpers::UfwCommand.resolve_insert`, which reproduces
  # community.general's own rule-number arithmetic (including its
  # no-rules-yet fallback positions and its
  # insert-past-the-end-means-append-instead behavior) field-for-field
  # from source. Like the rest of this plugin, the arithmetic itself is
  # source-verified but not further behavior-verified end-to-end (see the
  # netfilter-access note above).
  class UfwPlugin < BasePlugin
    def execute : PluginResult
      if state = @params["state"]?
        return run_state(state)
      end

      if logging = @params["logging"]?
        return run_simple(PluginHelpers::UfwCommand.logging_command(logging), ufw_state_key: "logging", ufw_state_value: logging)
      end

      if default_value = @params["default"]? || @params["policy"]?
        # `policy` is real community.general's ALIAS for `default`
        # (argument_spec: default=dict(aliases=['policy'], ...)) - found
        # via Oefenweb.ufw (round 196), whose tasks use the newer
        # `policy:`/`direction:` pair; this plugin only knew `default:`
        # and rejected the task with "one of state, logging, default, or
        # rule is required" where real ansible rc=0'd.
        direction = @params["direction"]? || "incoming"
        cmd = PluginHelpers::UfwCommand.default_command(default_value, @params["direction"]?)
        return run_simple(cmd, ufw_state_key: "default-#{direction}", ufw_state_value: default_value)
      end

      if @params["rule"]?
        return run_rule
      end

      PluginResult.new(changed: false, failed: true, msg: "one of state, logging, default, or rule is required")
    end

    private def run_state(state : String) : PluginResult
      cmd = PluginHelpers::UfwCommand.state_command(state)
      unless cmd
        return PluginResult.new(changed: false, failed: true, msg: "state must be one of enabled, disabled, reloaded, reset")
      end

      # reloaded/reset always count as changed (real ufw.py: `if value in
      # ['reloaded', 'reset']: changed = True` unconditionally); enabled/
      # disabled only actually change anything if the firewall wasn't
      # already in that state - matches ufw.py's own pre-state comparison
      # (`ufw_enabled = pre_state.find(" active") != -1`, checked against
      # both real and check-mode runs). Previously this used the state
      # COMMAND's own exit code as "changed" - `ufw enable` exits 0
      # whether or not anything actually changed (real ufw prints
      # "Firewall is active and enabled on system startup" and exits 0
      # even when already enabled), so `state: enabled`/`disabled`
      # reported changed: true on every single run, never converging.
      # Found benchmarking robertdebock.firewall's own "Enable ufw" task.
      changed = if state == "reloaded" || state == "reset"
                  true
                else
                  currently_enabled = ufw_currently_enabled?
                  (state == "enabled" && !currently_enabled) || (state == "disabled" && currently_enabled)
                end

      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: changed, failed: false, msg: "Would run: #{cmd} (check mode)")
      end

      result = remote_exec(cmd)
      PluginResult.new(changed: changed, failed: result[:exit_code] != 0, msg: result[:stdout])
    end

    # "Status: active" (verbose) / a bare "active" appearing in `ufw
    # status` - matches ufw.py's own `pre_state.find(" active") != -1`
    # check (the leading space is deliberate there too: "active" alone
    # would also match "inactive").
    private def ufw_currently_enabled? : Bool
      result = remote_exec("ufw status verbose")
      result[:stdout].includes?(" active")
    end

    private def run_simple(cmd : String, ufw_state_key : String? = nil, ufw_state_value : String? = nil) : PluginResult
      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "Would run: #{cmd} (check mode)")
      end

      # Real community.general.ufw computes `changed` for default-policy /
      # logging commands by diffing `ufw status verbose` BEFORE and AFTER
      # the command (pre_state vs post_state): if the relevant line is
      # identical, changed=false even though the command ran. Blindly
      # marking changed on exit 0 made every warm pass report
      # changed=true where real ansible reported ok (Oefenweb.ufw,
      # round 196: warm crystal changed=4 vs real changed=0).
      pre_status = if ufw_state_key
                     remote_exec("ufw status verbose")[:stdout]
                   end

      result = remote_exec(cmd)
      changed = result[:exit_code] == 0

      if ufw_state_key
        post_status = remote_exec("ufw status verbose")[:stdout]
        changed = result[:exit_code] == 0 &&
                  extract_status_fragment(pre_status.not_nil!, ufw_state_key) !=
                  extract_status_fragment(post_status, ufw_state_key)
      end

      PluginResult.new(changed: changed, failed: result[:exit_code] != 0, msg: result[:stdout])
    end

    # Returns the status line relevant to *key* ("Default: ..." for a
    # default-<direction> key, "Logging: ..." for logging), or "" when
    # absent (e.g. "Status: inactive" has no Default line at all).
    private def extract_status_fragment(status : String, key : String) : String
      status.each_line do |line|
        if key.starts_with?("default-") && line.includes?("Default:")
          return line.strip
        elsif key == "logging" && line.includes?("Logging:")
          return line.strip
        end
      end
      ""
    end

    private def run_rule : PluginResult
      check_mode = is_true?(@params["check_mode"]?)
      cmd = PluginHelpers::UfwCommand.rule_command(resolved_insert_params, dry_run: check_mode)

      result = remote_exec(cmd)
      changed = PluginHelpers::UfwCommand.changed_from_output?(result[:stdout])
      # Surface stderr on failure - real Ansible shows the ufw binary's
      # stderr in the task failure, and dropping it (as this used to)
      # made rule failures undiagnosable (Oefenweb.ufw, round 196:
      # failed with an empty message because ufw wrote its error to
      # stderr only).
      msg = result[:stdout]
      if result[:exit_code] != 0 && !result[:stderr].empty?
        msg = "#{msg}\n#{result[:stderr]}".strip
      end
      PluginResult.new(changed: changed, failed: result[:exit_code] != 0, msg: msg)
    end

    # `insert_relative_to:` other than the default `zero` needs to query
    # `ufw status numbered` before the rule command can even be built -
    # `zero` (by far the common case) needs no query at all. Returns a
    # copy of @params with `insert` replaced by the resolved absolute
    # position, or removed entirely if that position would fall past the
    # last existing rule (real Ansible's own "just append, no insert
    # flag" fallback for that case).
    private def resolved_insert_params : Hash(String, String)
      insert = @params["insert"]?.try(&.to_i?)
      relative_to = @params["insert_relative_to"]? || "zero"
      return @params unless insert && relative_to != "zero"

      status = remote_exec("ufw status numbered")
      resolved = PluginHelpers::UfwCommand.resolve_insert(insert, relative_to, status[:stdout])

      params = @params.dup
      if resolved
        params["insert"] = resolved.to_s
      else
        params.delete("insert")
      end
      params
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::UfwPlugin.new(config)
plugin.run

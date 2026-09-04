#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ufw_command"

module Krikri
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
  #   (see `src/krikri/plugin_helpers/ufw_command.cr`)
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
    # real community.general.ufw's own argument_spec aliases. Only
    # `policy` (for `default`) was handled before, and the omission of
    # the rest was not cosmetic: `port:` is the alias of `to_port`, and a
    # dropped port turns `ufw: rule=allow port=22 proto=tcp` into `ufw
    # allow from any to any proto tcp` - a rule opening EVERY tcp port
    # instead of 22, installed silently with the task reporting changed.
    # Confirmed live against real community.general on a NET_ADMIN
    # container by diffing `### tuple` lines from /etc/ufw/user.rules:
    # real Ansible writes `allow tcp 22 ...`, this engine wrote `allow
    # tcp any ...`.
    #
    # It also explains the warm-run `changed` delta this was filed under
    # (round 196, Oefenweb.ufw): every port rule collapsed onto the SAME
    # any->any tuple, so each run's rules overwrote each other's action
    # (allow, then limit, then allow...) and never converged.
    PARAM_ALIASES = {
      "policy"   => "default",
      "if"       => "interface",
      "if_in"    => "interface_in",
      "if_out"   => "interface_out",
      "from"     => "from_ip",
      "src"      => "from_ip",
      "dest"     => "to_ip",
      "to"       => "to_ip",
      "port"     => "to_port",
      "protocol" => "proto",
      "app"      => "name",
    }

    def initialize(config : JSON::Any)
      super(config)
      PARAM_ALIASES.each do |alias_name, canonical|
        if (value = @params[alias_name]?) && !@params.has_key?(canonical)
          @params[canonical] = value
        end
      end
    end

    def execute : PluginResult
      if error = validate_params
        return PluginResult.new(changed: false, failed: true, msg: error)
      end

      if state = @params["state"]?
        return run_state(state)
      end

      if logging = @params["logging"]?
        return run_simple(PluginHelpers::UfwCommand.logging_command(logging), ufw_state_key: "logging", ufw_state_value: logging)
      end

      if default_value = @params["default"]?
        # `policy` reaches this as `default` via PARAM_ALIASES - found
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

    # real community.general's own argument_spec constraints, which it
    # enforces before running anything. Without these the task still
    # fails, but with whatever ufw says about the malformed command it
    # was handed ("ERROR: Invalid token 'on'" for a bare `interface:`),
    # instead of naming the parameter that is actually missing. Verified
    # live: real Ansible answers "missing parameter(s) required by
    # 'interface': direction" for exactly that task.
    private def validate_params : String?
      if @params.has_key?("interface") && !@params.has_key?("direction")
        return "missing parameter(s) required by 'interface': direction"
      end

      exclusive = {"name", "proto", "logging"}.select { |key| @params.has_key?(key) }
      if exclusive.size > 1
        return "parameters are mutually exclusive: #{exclusive.join(", ")}"
      end

      {"interface_in", "interface_out"}.each do |key|
        if @params.has_key?("direction") && @params.has_key?(key)
          return "parameters are mutually exclusive: direction|#{key}"
        end
      end

      nil
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

      if true?(@params["check_mode"]?)
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
      if true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "Would run: #{cmd} (check mode)")
      end

      # Real community.general.ufw computes `changed` differently per
      # command type (verified against the module's own source):
      # - default: pre vs post `ufw status verbose` Default-line diff;
      # - logging: from the PRE state alone - "Logging: off" -> anything
      #   non-off is changed, and a requested level != the current level
      #   is changed, even though `ufw logging <same-level>` no-ops.
      # The earlier pre-check-skip and post-diff approaches each matched
      # only one of the two (Oefenweb.ufw round 196: warm changed=4 vs 0,
      # then cold logging changed=0 vs real 1).
      pre_status = if ufw_state_key
                     remote_exec("ufw status verbose")[:stdout]
                   end

      result = remote_exec(cmd)
      ran_ok = result[:exit_code] == 0

      changed = compute_changed(ran_ok, ufw_state_key, ufw_state_value, pre_status)

      PluginResult.new(changed: changed, failed: !ran_ok, msg: result[:stdout])
    end

    private def compute_changed(ran_ok : Bool, ufw_state_key : String?, ufw_state_value : String?, pre_status : String?) : Bool
      if ufw_state_key == "logging" && (value = ufw_state_value)
        logging_changed?(ran_ok, value, pre_status || "")
      elsif ufw_state_key
        post_status = remote_exec("ufw status verbose")[:stdout]
        ran_ok &&
          extract_status_fragment(pre_status || "", ufw_state_key) !=
            extract_status_fragment(post_status, ufw_state_key)
      else
        ran_ok
      end
    end

    private def logging_changed?(ran_ok : Bool, value : String, pre_status : String) : Bool
      return false unless ran_ok

      m = /Logging: (on|off)(?: \(([a-z]+)\))?/.match(pre_status)
      return true unless m

      current_on_off = m[1]
      current_level = m[2]?
      if value == "off"
        current_on_off != "off"
      elsif current_on_off == "off"
        true
      else
        value != "on" && value != current_level
      end
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

    # The rule files real community.general greps for its `### tuple`
    # lines - the authoritative record of what ufw actually holds, and
    # the only thing that distinguishes "re-applied an identical rule"
    # from "changed one".
    USER_RULES_FILES = %w[
      /lib/ufw/user.rules /lib/ufw/user6.rules
      /etc/ufw/user.rules /etc/ufw/user6.rules
      /var/lib/ufw/user.rules /var/lib/ufw/user6.rules
    ]

    private def run_rule : PluginResult
      check_mode = true?(@params["check_mode"]?)
      cmd = PluginHelpers::UfwCommand.rule_command(resolved_insert_params, dry_run: check_mode)

      # Real community.general does NOT read `changed` out of the ufw
      # command's own output for a rule: in normal mode it snapshots
      # `ufw status verbose` AND the rule tuples before and after, and
      # reports changed only if either actually moved
      # (`changed = (pre_state != post_state) or (pre_rules !=
      # post_rules)`). Parsing the command's stdout instead - which this
      # did - makes `changed` depend on ufw's wording ("Rule added" vs
      # "Skipping adding existing rule"), which is only equivalent while
      # the rule text is byte-identical to what is already installed;
      # any difference at all, including one this engine introduced, then
      # reads as a real change forever.
      pre_state = check_mode ? "" : remote_exec("ufw status verbose")[:stdout].to_s
      pre_rules = check_mode ? "" : current_rule_tuples

      result = remote_exec(cmd)

      changed = if check_mode
                  PluginHelpers::UfwCommand.changed_from_output?(result[:stdout])
                else
                  post_state = remote_exec("ufw status verbose")[:stdout].to_s
                  pre_state != post_state || pre_rules != current_rule_tuples
                end
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

    # `grep -h '^### tuple' <every user.rules file>` - real Ansible's own
    # `get_current_rules()`, verbatim including the file list and the
    # `-h` (no filename prefixes, so the comparison is over rule text
    # alone).
    private def current_rule_tuples : String
      remote_exec("grep -h '^### tuple' #{USER_RULES_FILES.join(' ')} 2>/dev/null")[:stdout].to_s
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

plugin = Krikri::UfwPlugin.new(config)
plugin.run

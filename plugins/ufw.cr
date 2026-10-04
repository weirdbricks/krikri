#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ufw_command"
require "../src/krikri/plugin_helpers/get_bin_path"

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
  #
  # Failure propagation: real ufw.py routes EVERY ufw invocation
  # (pre/post `ufw status verbose`, the state/rule command itself)
  # through its own execute() helper, which fails the module with
  # `msg=err or out` plus the accumulated `commands:` list the moment a
  # command exits non-zero. This plugin used to read only the stdout of
  # the pre/post status probes and ignored their exit codes entirely -
  # so in a container without CAP_NET_ADMIN (where ufw's own iptables
  # probe fails with "Permission denied (you must be root)" and even
  # `ufw status verbose` exits non-zero), the rule command still
  # "succeeded" with "Rules updated" and the task reported changed:
  # true where real Ansible failed. Found via an ad-hoc CLI comparison
  # sweep against real ansible, 2026-09-13.
  class UfwPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation
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

    # Raised by #ufw_exec when a ufw command exits non-zero, carrying
    # real ufw.py's execute() failure payload: `msg=err or out` plus the
    # accumulated commands list.
    class UfwCommandFailure < Exception
    end

    # Real ufw.py resolves ufw and grep via get_bin_path(required=True)
    # before anything runs, and its `commands:` failure/success field
    # shows the RESOLVED absolute paths ("/usr/sbin/ufw status verbose").
    # Same extra dirs as ServicePlugin/ModprobePlugin for the non-login
    # shell PATH gap.
    REQUIRED_BINARIES = %w[ufw grep]
    EXTRA_BIN_DIRS    = %w[/sbin /usr/sbin /bin /usr/bin]
    USER_RULES_FILES  = %w[
      /lib/ufw/user.rules /lib/ufw/user6.rules
      /etc/ufw/user.rules /etc/ufw/user6.rules
      /var/lib/ufw/user.rules /var/lib/ufw/user6.rules
    ]

    @bins = Hash(String, String).new
    @searched_paths = ""
    @commands = [] of String
    @changed = false

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
        return error
      end

      begin
        result = dispatch
      rescue e : UfwCommandFailure
        # Real ufw.py's fail_json(msg=err or out, commands=cmds) keeps its
        # kwargs ahead of the standard keys (same kwargs-first rule the
        # lvol/parted failures show): registered order
        # [commands, failed, msg, changed, exception] - the container
        # oracle run (no CAP_NET_ADMIN) confirmed it live. A get_bin_path
        # failure carries no commands key, which the order simply skips.
        result = PluginResult.new(changed: false, failed: true, msg: e.message.to_s,
          key_order: ["commands", "failed", "msg", "changed", "exception"])
      end

      # Real ufw.py carries the accumulated commands on BOTH success
      # (exit_json(commands=cmds)) and failure (fail_json(msg=err or
      # out, commands=cmds)) - but a get_bin_path failure happens
      # before anything ran, and its fail_json carries no commands.
      unless @commands.empty?
        result.extra["commands"] = JSON.parse(@commands.to_json)
      end
      # Real ufw.py's exit shape (its own main() tail): every normal-mode
      # exit is exit_json(changed=changed, commands=cmds,
      # msg=post_state.rstrip()), while check mode returns
      # exit_json(changed=changed, commands=cmds) with NO msg key at all
      # (the dry-run output only feeds changed:, never the result). The
      # controller backfills failed last, giving the registered orders
      # [changed, commands, msg, failed] / [changed, commands, failed]
      # (round-992002 ufw_* captures).
      unless result.failed?
        result.key_order = true?(@params["_ansible_check_mode"]?) ? ["changed", "commands"] : ["changed", "commands", "msg"]
      end
      result
    end

    # Real ufw.py's own `command_keys`, in ITS declaration order.
    # Every one of these that a task sets is a command real runs, in
    # this order, inside ONE invocation - this plugin used to dispatch
    # first-match-wins with an early return per key, so a task
    # combining `state:` with a `rule:`/`default:`/`logging:` (the
    # one-task "activate everything" shape konstruktoid.hardening
    # uses) ran `ufw -f enable` and silently DROPPED the rest: real
    # installs the rule/sets the default/logging, this engine reported
    # success having applied none of it, so `changed`, `commands` and
    # `msg` all diverged (round 1000, ufw_active_* real-host captures).
    # `log:`/`direction:`/`comment:` are modifiers of the rule branch,
    # not commands of their own.
    COMMAND_KEYS = %w[state default rule logging]

    private def dispatch : PluginResult
      resolve_required_binaries

      # Real ufw.py's main() captures the pre state and the rule tuples
      # ONCE, right after get_bin_path and before the command loop - the
      # first two entries of every probe's commands list
      # (round-995002 captures: "ufw status verbose" then the
      # `grep -h '^### tuple' ...` sweep, for state/default/logging/rule
      # alike).
      pre_state = ufw_exec("#{@bins["ufw"]} status verbose")
      pre_rules = current_rule_tuples

      # Real ufw.py's `commands = {key: params[key] for key in
      # command_keys if params[key]}` - a falsy value drops out, so only
      # the keys a task actually requested reach the loop.
      requested = COMMAND_KEYS.each_with_object({} of String => String) do |key, commands|
        value = @params[key]?
        commands[key] = value if value && value != ""
      end
      if requested.empty?
        return PluginResult.new(changed: false, failed: true, msg: "one of state, logging, default, or rule is required")
      end

      @changed = false
      requested.each do |command, value|
        # A branch returning a PluginResult aborts the whole task, which
        # is how real's in-loop fail_json() calls behave.
        if failure = run_command(command, value, pre_state, pre_rules)
          return failure
        end
      end

      # Real ufw.py's tail: check mode exits right after the loop with
      # no post probes and no msg key at all; normal mode takes ONE
      # post `ufw status verbose` snapshot (the msg= exit value) and,
      # only while nothing has counted as changed yet, ONE post tuples
      # read whose diff against the single pre snapshot decides
      # `changed`.
      if true?(@params["_ansible_check_mode"]?)
        return PluginResult.new(changed: @changed, failed: false)
      end

      post_state = ufw_exec("#{@bins["ufw"]} status verbose")
      unless @changed
        post_rules = current_rule_tuples
        @changed = pre_state != post_state || pre_rules != post_rules
      end

      PluginResult.new(changed: @changed, failed: false, msg: post_state.rstrip)
    end

    # Real ufw.py's `for (command, value) in commands.items()` body, one
    # branch per command key. Every branch folds its own verdict into the
    # loop-wide `changed` accumulator - real sets that one flag across
    # all commands, it is never per-command - and may return a
    # PluginResult to abort.
    private def run_command(command : String, value : String, pre_state : String, pre_rules : String) : PluginResult?
      case command
      when "state"   then apply_state(value, pre_state)
      when "default" then apply_default(value, pre_state)
      when "rule"    then apply_rule(pre_rules)
      when "logging" then apply_logging(value, pre_state)
      end
    end

    # Real community.general.ufw's full AnsibleModule setup surface,
    # live-verified via the podman-diff ufw case: argument-spec checks
    # (choices in spec declaration order, bool/int conversion with
    # convert wording) run in main()-independent module init BEFORE
    # anything else, then the mutually-exclusive tuples (one message per
    # tuple, listing the WHOLE tuple pipe-joined regardless of which
    # members are present), then required_one_of, then required_by,
    # then unsupported params. get_bin_path("ufw"/"grep") only runs
    # after all of that in real ufw.py - this plugin used to resolve the
    # binaries first, so every validation task in a ufw-less container
    # failed with the get_bin_path message instead of naming the actual
    # argument error.
    SPEC = {
      "state"              => %w[],
      "default"            => %w[policy],
      "logging"            => %w[],
      "direction"          => %w[],
      "delete"             => %w[],
      "route"              => %w[],
      "insert"             => %w[],
      "insert_relative_to" => %w[],
      "rule"               => %w[],
      "interface"          => %w[if],
      "interface_in"       => %w[if_in],
      "interface_out"      => %w[if_out],
      "log"                => %w[],
      "from_ip"            => %w[from src],
      "from_port"          => %w[],
      "to_ip"              => %w[dest to],
      "to_port"            => %w[port],
      "proto"              => %w[protocol],
      "name"               => %w[app],
      "comment"            => %w[],
    }

    # Real argument_spec choices, declaration order (NOT sorted).
    CHOICES = {
      "state"              => %w[enabled disabled reloaded reset],
      "default"            => %w[allow deny reject],
      "logging"            => %w[full high low medium off on],
      "direction"          => %w[in incoming out outgoing routed],
      "insert_relative_to" => %w[zero first-ipv4 last-ipv4 first-ipv6 last-ipv6],
      "rule"               => %w[allow deny limit reject],
      "proto"              => %w[ah any esp ipv6 tcp udp gre igmp vrrp],
    }

    private def validate_params : PluginResult?
      # Spec-order parameter validation: choices, then bool/int
      # conversion, only for params actually passed (the defaults are
      # valid by construction).
      SPEC.each do |param, _aliases|
        raw = @params[param]?
        next unless raw
        if error = validate_param_value(param, raw)
          return error
        end
      end

      if error = check_mutually_exclusive
        return error
      end

      unless {"state", "default", "rule", "logging"}.any? { |key| @params.has_key?(key) }
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: state, default, rule, logging")
      end

      if @params.has_key?("interface") && !@params.has_key?("direction")
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'interface': direction")
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.ufw", unsupported, SPEC)
        end
      end

      nil
    end

    private def validate_param_value(param : String, raw : String) : PluginResult?
      if allowed = CHOICES[param]?
        unless allowed.includes?(raw)
          return choices_error(param, allowed, raw)
        end
      end
      case param
      when "delete", "route", "log"
        return bool_type_error(param, raw) unless bool_convertible?(raw)
      when "insert"
        unless raw.strip.matches?(/\A[+-]?\d(_?\d)*\z/)
          return int_type_error(param, raw)
        end
      end
      nil
    end

    private def check_mutually_exclusive : PluginResult?
      if @params.has_key?("name") || @params.has_key?("proto") || @params.has_key?("logging")
        present = {"name", "proto", "logging"}.count { |key| @params.has_key?(key) }
        if present > 1
          return PluginResult.new(changed: false, failed: true,
            msg: "parameters are mutually exclusive: name|proto|logging")
        end
      end
      if @params.has_key?("direction") && @params.has_key?("interface_in")
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: direction|interface_in")
      end
      if @params.has_key?("direction") && @params.has_key?("interface_out")
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: direction|interface_out")
      end
      nil
    end

    # Real ufw.py's state branch: reloaded/reset always count as changed
    # (`if value in ['reloaded', 'reset']: changed = True`,
    # unconditionally and BEFORE the check-mode branch, so in check mode
    # too). Check mode decides enabled/disabled from the PRE state's
    # ` active` marker alone and never runs the command; normal mode
    # runs `ufw -f <verb>`.
    private def apply_state(state : String, pre_state : String) : PluginResult?
      cmd = PluginHelpers::UfwCommand.state_command(state)
      unless cmd
        return PluginResult.new(changed: false, failed: true, msg: "state must be one of enabled, disabled, reloaded, reset")
      end

      @changed = true if state == "reloaded" || state == "reset"

      if true?(@params["_ansible_check_mode"]?)
        # "active" would also match "inactive", hence the space
        ufw_enabled = pre_state.includes?(" active")
        @changed = true if (state == "disabled" && ufw_enabled) || (state == "enabled" && !ufw_enabled)
        return nil
      end

      ufw_exec(ufw_bin_cmd(cmd))
      nil
    end

    # Real ufw.py's logging branch: `changed` comes from the PRE state
    # alone, in check mode and out of it alike, because `ufw logging
    # <same-level>` is a no-op ufw reports no differently - an earlier
    # post-diff approach matched only one of the two (Oefenweb.ufw round
    # 196: warm changed=4 vs 0, then cold logging changed=0 vs real 1).
    private def apply_logging(logging : String, pre_state : String) : PluginResult?
      @changed = true if logging_changed?(true, logging, pre_state)

      unless true?(@params["_ansible_check_mode"]?)
        ufw_exec(ufw_bin_cmd(PluginHelpers::UfwCommand.logging_command(logging)))
      end
      nil
    end

    # Real ufw.py's default branch: normal mode just runs
    # `ufw default <value> [<direction>]` and leaves `changed` alone -
    # the tail's pre/post whole-state + rule-tuple diff decides it -
    # while check mode decides `changed` from the PRE state's Default
    # line. (`policy` reaches this as `default` via PARAM_ALIASES -
    # found via Oefenweb.ufw round 196, whose tasks use the newer
    # `policy:`/`direction:` pair.)
    private def apply_default(value : String, pre_state : String) : PluginResult?
      direction = @params["direction"]?

      if true?(@params["_ansible_check_mode"]?)
        @changed = true if default_check_mode_changed?(pre_state, value, direction)
        return nil
      end

      ufw_exec(ufw_bin_cmd(PluginHelpers::UfwCommand.default_command(value, direction)))
      nil
    end

    # Real ufw.py's check-mode branch for `default:`: the Default line
    # regex over the PRE state; a missing line means changed, and the
    # current value for the requested direction counts as unchanged only
    # when it equals the requested value or is "disabled".
    private def default_check_mode_changed?(pre_state : String, value : String, direction : String?) : Bool
      m = /Default: (deny|allow|reject) \(incoming\), (deny|allow|reject) \(outgoing\), (deny|allow|reject|disabled) \(routed\)/.match(pre_state)
      return true unless m
      current = case direction || "incoming"
                when "outgoing" then m[2]
                when "routed"   then m[3]
                else                 m[1]
                end
      !(current == value || current == "disabled")
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

    # The rule files real community.general greps for its `### tuple`
    # lines - the authoritative record of what ufw actually holds, and
    # the only thing that distinguishes "re-applied an identical rule"
    # from "changed one".
    #
    # Real ufw.py's rule branch: it calls ufw_version() before running
    # the rule command - the `ufw --version` probe (it feeds the
    # comment-support version gate, and it is recorded in commands like
    # every other invocation, inside whatever place the rule sits in the
    # command loop). A non-parsing `ufw --version` output fails the
    # module with real's own wording. In CHECK MODE the dry-run output
    # is compared against the pre rules to set `changed`; in NORMAL mode
    # the branch itself never sets `changed` at all - the tail's
    # pre/post state + tuple diff does, after the loop.
    #
    # Real community.general does NOT read `changed` out of the ufw
    # command's own output for a rule: it snapshots `ufw status verbose`
    # AND the rule tuples before and after, and reports changed only if
    # either actually moved (`changed = (pre_state != post_state) or
    # (pre_rules != post_rules)`). Parsing the command's stdout instead
    # - which this did - makes `changed` depend on ufw's wording
    # ("Rule added" vs "Skipping adding existing rule"), which is only
    # equivalent while the rule text is byte-identical to what is
    # already installed; any difference at all, including one this
    # engine introduced, then reads as a real change forever. All three
    # probes go through #ufw_exec: a failing pre/post `ufw status
    # verbose` (no CAP_NET_ADMIN, missing ufw, ...) fails the task with
    # real ufw.py's execute() behavior instead of reading as an empty
    # snapshot.
    private def apply_rule(pre_rules : String) : PluginResult?
      check_mode = true?(@params["_ansible_check_mode"]?)
      cmd = PluginHelpers::UfwCommand.rule_command(resolved_insert_params, dry_run: check_mode)

      version_out = ufw_exec("#{@bins["ufw"]} --version")
      unless PluginHelpers::UfwCommand.version_parses?(version_out)
        # Real ufw_version()'s own failure: fail_json(msg="Failed to get
        # ufw version.", rc=0, out=out) - kwargs first, then failed/msg,
        # changed backfilled last.
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to get ufw version.",
          rc: 0, out: version_out,
          key_order: ["rc", "out", "failed", "msg"])
      end

      # The pre-probes run in CHECK MODE too (real takes them before its
      # command loop unconditionally - the container oracle caught this
      # engine reporting a dry-run success where real failed the task on
      # the failing pre-status probe).
      result = remote_exec(ufw_bin_cmd(cmd))
      @commands << ufw_bin_cmd(cmd)
      if result[:exit_code] != 0
        raise UfwCommandFailure.new(PluginHelpers::UfwCommand.exec_failure_msg(result[:stdout].to_s, result[:stderr].to_s))
      end

      if check_mode
        # Real ufw.py's check-mode rule logic: when EVERY line of the
        # dry-run output says "Skipping" nothing changes; otherwise the
        # `### tuple` lines of the dry-run output are diffed against the
        # pre rules (ipv4/ipv6-filtered when the rule addresses an ip
        # literal of that family).
        @changed = true if PluginHelpers::UfwCommand.check_mode_rule_changed?(result[:stdout], pre_rules,
                             @params["from_ip"]? || "any", @params["to_ip"]? || "any")
      end
      nil
    end

    # `grep -h '^### tuple' <every user.rules file>` - real Ansible's own
    # `get_current_rules()`, verbatim including the file list and the
    # `-h` (no filename prefixes, so the comparison is over rule text
    # alone) - and WITHOUT a stderr redirect: real's captured commands
    # list shows the bare grep, and its failure tolerance comes from
    # ignore_error=True (a no-rules-yet grep exiting 1 is normal, not a
    # failure).
    private def current_rule_tuples : String
      ufw_exec("#{@bins["grep"]} -h '^### tuple' #{USER_RULES_FILES.join(' ')}", ignore_error: true)
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

      # Real ufw.py reads the numbered status with a bare run_command and
      # IGNORES its rc there - only the parsed lines matter (an empty
      # output means "no rules yet" and takes the fallback positions).
      status = remote_exec("#{@bins["ufw"]} status numbered")
      resolved = PluginHelpers::UfwCommand.resolve_insert(insert, relative_to, status[:stdout])

      params = @params.dup
      if resolved
        params["insert"] = resolved.to_s
      else
        params.delete("insert")
      end
      params
    end

    # Rewrites a helper-built "ufw ..." command line to invoke the
    # resolved absolute binary - real ufw.py's commands list shows
    # "/usr/sbin/ufw status verbose", not a bare PATH lookup.
    private def ufw_bin_cmd(cmd : String) : String
      cmd.sub(/^ufw /, "#{@bins["ufw"]} ")
    end

    # Real ufw.py's get_bin_path("ufw"/"grep", required=True): resolve
    # both up front and fail the module with its exact
    # "Failed to find required executable ... in paths: ..." message when
    # either is missing, instead of letting later commands fail with
    # 127 (or, worse, reading an empty status snapshot as success).
    private def resolve_required_binaries : Nil
      script = <<-SH
      for name in #{REQUIRED_BINARIES.join(' ')}; do
        found=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          if [ -z "$found" ] && [ -x "$d/$name" ]; then found="$d/$name"; fi
        done
        printf 'bin:%s=%s\n' "$name" "$found"
      done
      searched=""
      for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
        case ":$searched:" in *":$d:"*) ;; *) searched="${searched:+$searched:}$d" ;; esac
      done
      printf 'searched=%s\n' "$searched"
      SH

      remote_exec(script)[:stdout].to_s.each_line do |line|
        key, _, value = line.strip.partition('=')
        if key.starts_with?("bin:")
          @bins[key.lchop("bin:")] = value
        elsif key == "searched"
          @searched_paths = value
        end
      end

      missing = REQUIRED_BINARIES.find { |name| @bins[name]?.to_s.empty? }
      if missing
        raise UfwCommandFailure.new(PluginHelpers::GetBinPath.missing_executable_error(missing, @searched_paths))
      end
    end

    # Real ufw.py's execute(): run the command, record it in the
    # commands list, and fail the module with `msg=err or out` the
    # moment it exits non-zero - unless ignore_error, which real
    # applies ONLY to the rule-tuples grep (a no-rules-yet grep exits
    # 1). Returns the command's stdout.
    private def ufw_exec(cmd : String, ignore_error : Bool = false) : String
      result = remote_exec(cmd)
      @commands << cmd
      if result[:exit_code] != 0 && !ignore_error
        raise UfwCommandFailure.new(PluginHelpers::UfwCommand.exec_failure_msg(result[:stdout].to_s, result[:stderr].to_s))
      end
      result[:stdout].to_s
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::UfwPlugin.new(config)
plugin.run

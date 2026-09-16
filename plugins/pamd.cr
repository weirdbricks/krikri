#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  # pamd plugin - edits a /etc/pam.d/<name> service config. Ported to
  # match community.general.pamd's own Python logic (linked-list-of-
  # rules model, control normalization, insert-skip-comments behavior)
  # rather than a simplified reimplementation - verified against the
  # real module source (ansible_collections/community/general/plugins/
  # modules/pamd.py).
  #
  # A PAM config line has the shape `TYPE CONTROL MODULE_PATH
  # [MODULE_ARGUMENTS]`.
  #
  # Parameters:
  # - name, type, control, module_path (all required, always - real
  #   Ansible requires `control` even for state: absent)
  # - new_type / new_control / new_module_path: required for state:
  #   before/after; used by state: updated to change the matched rule
  # - module_arguments: replaces (updated), or is added-to/removed-from
  #   (args_present/args_absent) the matched rule's arguments
  # - state: updated (default) / before / after / absent / args_present
  #   / args_absent
  # - path (default /etc/pam.d), backup, check_mode
  #
  # Matching (`matches?`): type/control/module_path must equal a rule's
  # own type/NORMALIZED-control/path exactly - the CONTROL PARAMETER
  # ITSELF IS NOT NORMALIZED, only what's stored from parsing/writing a
  # rule is (mirrors the real module's `PamdRule.matches` comparing the
  # raw match arg against the normalized `rule_control` property).
  class PamdRuleLine
    property rule_type : String
    property control : String # already normalized
    property path : String
    property args : Array(String)
    property kind : Symbol # :rule, :comment, :empty, :include, :unparsed
    property raw : String  # verbatim text for non-rule kinds

    def initialize(@rule_type, control : String, @path, @args = [] of String, @kind = :rule, @raw = "")
      @control = PamdPlugin.normalize_control(control)
    end

    def self.other(raw : String, kind : Symbol) : PamdRuleLine
      line = PamdRuleLine.new("", "", "", [] of String, kind, raw)
      line
    end

    def matches?(type : String, control_param : String, path : String) : Bool
      return false unless @kind == :rule
      @rule_type == type && @control == control_param && @path == path
    end

    def to_s(io : IO) : Nil
      return io << @raw unless @kind == :rule
      io << @rule_type.ljust(11) << @control << " " << @path
      io << " " << @args.join(" ") unless @args.empty?
    end
  end

  RULE_RE = /\A(-?(?:auth|account|session|password))\s+(\[.*\]|\S*)\s+(\S*)\s*(.*)\z/
  ARG_RE  = /(\[[^\]]*\]|\S*)/

  class PamdPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real pamd.py's own constants - type/new_type choices, the simple
    # control words, and the bracketed-control value/action vocabularies
    # (PamdRule.valid_*), plus the state choices in the real
    # argument_spec's (sorted) order.
    VALID_TYPES           = ["account", "-account", "auth", "-auth", "password", "-password", "session", "-session"]
    STATE_CHOICES         = ["absent", "after", "args_absent", "args_present", "before", "updated"]
    VALID_SIMPLE_CONTROLS = ["required", "requisite", "sufficient", "optional", "include", "substack", "definitive"]
    VALID_CONTROL_VALUES  = ["success", "open_err", "symbol_err", "service_err", "system_err", "buf_err", "perm_denied", "auth_err", "cred_insufficient", "authinfo_unavail", "user_unknown", "maxtries", "new_authtok_reqd", "acct_expired", "session_err", "cred_unavail", "cred_expired", "cred_err", "no_module_data", "conv_err", "authtok_err", "authtok_recover_err", "authtok_lock_busy", "authtok_disable_aging", "try_again", "ignore", "abort", "authtok_expired", "module_unknown", "bad_item", "conv_again", "incomplete", "default"]
    VALID_CONTROL_ACTIONS = ["ignore", "bad", "die", "ok", "done", "reset"]

    # Real argument_spec - no aliases.
    SPEC = {
      "name"             => %w[],
      "type"             => %w[],
      "control"          => %w[],
      "module_path"      => %w[],
      "new_type"         => %w[],
      "new_control"      => %w[],
      "new_module_path"  => %w[],
      "module_arguments" => %w[],
      "state"            => %w[],
      "path"             => %w[],
      "backup"           => %w[],
    }

    # Mirrors PamdRule.rule_control=: bracketed controls have their
    # brackets stripped, " = " collapsed to "=", and are re-joined on a
    # single space wrapped back in brackets; plain controls pass
    # through unchanged.
    def self.normalize_control(control : String) : String
      return control unless control.starts_with?('[')
      inner = control.gsub(" = ", "=").delete('[').delete(']')
      "[" + inner.split(' ').reject(&.empty?).join(" ") + "]"
    end

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      name = @params["name"]

      type = @params["type"]
      control = @params["control"]
      module_path = @params["module_path"]

      state = @params["state"]? || "updated"
      dir = expand_tilde(@params["path"]? || "/etc/pam.d")
      path = File.join(dir, name)
      check_mode = true?(@params["check_mode"]?)

      unless File.exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "Unable to open/read PAM module file #{path} with error [Errno 2] No such file or directory: '#{path}'.")
      end

      lines = parse_lines(File.read(path))

      changes = apply_state(lines, state, type, control, module_path)
      return changes if changes.is_a?(PluginResult)

      # Real runs service.validate() over EVERY line after taking the
      # action and before writing - an invalid rule (bad control, or an
      # unparseable line the parser kept verbatim) fails the module even
      # when nothing changed, and nothing is written.
      if err = validate_service(lines)
        return err
      end

      # Real community.general.pamd's success result is exactly
      # {changed, change_count, backupdest} - verified live against real
      # ansible (community.general 13.3.0 ad-hoc CLI comparison,
      # privileged podman container, 2026-09-13) - with no msg at all:
      # an idempotent no-op (rule matched, already had the desired
      # value) and a genuine no-such-rule case are BOTH
      # `changed: false, change_count: 0` (change_count counts rules
      # actually MODIFIED, not matched). The previous "No matching rule
      # in ..." msg therefore misreported the idempotent no-op as a
      # no-such-rule case, and the "Updated N rule(s)" msg was invented
      # too. backupdest is the backup file path (empty string when
      # backup: yes wasn't given or nothing changed - the backup is
      # only taken when the file is actually about to be written).
      backupdest = ""
      if changes > 0 && !check_mode
        backupdest = backup(path)
        write(path, lines)
      end

      PluginResult.new(changed: changes > 0, failed: false, msg: "", change_count: changes, backupdest: backupdest)
    end

    # Real AnsibleModule setup surface, in the validator's errors[0]
    # order (mutually exclusive -> required -> types -> choices ->
    # required_if -> unsupported) - all BEFORE the file is opened, so
    # e.g. state=before without the new_* triple fails the same way
    # against a missing service file (podman-diff P2/P4).
    private def validate_arguments : PluginResult?
      missing = ["name", "type", "control", "module_path"].select { |param| !@params[param]? }
      return missing_required_error(missing) unless missing.empty?

      type = @params["type"]
      return choices_error("type", VALID_TYPES, type) unless VALID_TYPES.includes?(type)

      if new_type = @params["new_type"]?
        return choices_error("new_type", VALID_TYPES, new_type) unless VALID_TYPES.includes?(new_type)
      end

      state = @params["state"]? || "updated"
      return choices_error("state", STATE_CHOICES, state) unless STATE_CHOICES.includes?(state)

      if bad_bool = @params["backup"]?
        return bool_type_error("backup", bad_bool) unless bool_convertible?(bad_bool)
      end

      if err = validate_state_requirements(state)
        return err
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.pamd", unsupported, SPEC)
        end
      end

      nil
    end

    # Real required_if entries: args_present/args_absent need
    # module_arguments, before/after need the whole new_* triple.
    private def validate_state_requirements(state : String) : PluginResult?
      if state == "args_present" || state == "args_absent"
        unless @params["module_arguments"]?
          return PluginResult.new(changed: false, failed: true,
            msg: "state is #{state} but all of the following are missing: module_arguments")
        end
      end

      if state == "before" || state == "after"
        missing_new = ["new_control", "new_type", "new_module_path"].select { |param| !@params[param]? }
        unless missing_new.empty?
          return PluginResult.new(changed: false, failed: true,
            msg: "state is #{state} but all of the following are missing: #{missing_new.join(", ")}")
        end
      end

      nil
    end

    # Real PamdService.validate(): every line must be a valid comment
    # (raw starts with '#'), @include (raw starts with '@include'), an
    # empty line, or a rule with a valid type and control. A bracketed
    # control's entries are "value=action" with value in
    # VALID_CONTROL_VALUES and action in VALID_CONTROL_ACTIONS or an
    # unsigned int.
    private def validate_service(lines : Array(PamdRuleLine)) : PluginResult?
      lines.each do |line|
        ok, msg = validate_line(line)
        return PluginResult.new(changed: false, failed: true, msg: msg) unless ok
      end
      nil
    end

    private def validate_line(line : PamdRuleLine) : {Bool, String}
      case line.kind
      when :comment
        return line.raw.starts_with?('#') ? {true, ""} : {false, "Rule is not valid #{line.raw}"}
      when :include
        return line.raw.starts_with?("@include") ? {true, ""} : {false, "Rule is not valid #{line.raw}"}
      when :empty
        return line.raw.strip.empty? ? {true, ""} : {false, "Rule is not valid #{line.raw}"}
      when :unparsed
        return {false, "Rule is not valid #{line.raw}"}
      end

      unless VALID_TYPES.includes?(line.rule_type)
        return {false, "Rule type, #{line.rule_type}, is not valid in rule #{line}"}
      end

      if line.control.starts_with?('[')
        return validate_bracketed_control(line)
      else
        unless VALID_SIMPLE_CONTROLS.includes?(line.control)
          return {false, "Rule control, #{line.control}, is not valid in rule #{line}"}
        end
      end

      {true, ""}
    end

    # A bracketed control's entries are "value=action" with value in
    # VALID_CONTROL_VALUES and action in VALID_CONTROL_ACTIONS or an
    # unsigned int.
    private def validate_bracketed_control(line : PamdRuleLine) : {Bool, String}
      line.control.lstrip('[').rstrip(']').split(' ').reject(&.empty?).each do |entry|
        parts = entry.split('=')
        if parts.size != 2
          return {false, "Rule control value, #{entry}, is not valid in rule #{line}"}
        end
        value, action = parts
        unless VALID_CONTROL_VALUES.includes?(value)
          return {false, "Rule control value, #{value}, is not valid in rule #{line}"}
        end
        unless VALID_CONTROL_ACTIONS.includes?(action) || action.matches?(/\A\d+\z/)
          return {false, "Rule control action, #{action}, is not valid in rule #{line}"}
        end
      end
      {true, ""}
    end

    private def apply_state(lines : Array(PamdRuleLine), state : String, type : String, control : String, module_path : String) : Int32 | PluginResult
      new_type = @params["new_type"]?
      new_control = @params["new_control"]?
      new_module_path = @params["new_module_path"]?
      module_arguments_raw = @params["module_arguments"]?

      case state
      when "updated"
        update_rule(lines, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw)
      when "before", "after"
        apply_insert(lines, state, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw)
      when "args_present"
        return PluginResult.new(changed: false, failed: true, msg: "state=args_present requires module_arguments") unless module_arguments_raw
        tokens = parse_module_arguments(module_arguments_raw) || [] of String
        if tokens.any?(&.starts_with?('['))
          return PluginResult.new(changed: false, failed: true, msg: "Unable to process bracketed '[' complex arguments with 'args_present'. Please use 'updated'.")
        end
        add_module_arguments(lines, type, control, module_path, module_arguments_raw)
      when "args_absent"
        return PluginResult.new(changed: false, failed: true, msg: "state=args_absent requires module_arguments") unless module_arguments_raw
        remove_module_arguments(lines, type, control, module_path, module_arguments_raw)
      when "absent"
        remove_matching(lines, type, control, module_path)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be one of updated/before/after/absent/args_present/args_absent, got '#{state}'")
      end
    end

    private def apply_insert(lines : Array(PamdRuleLine), state : String, type : String, control : String, module_path : String, new_type : String?, new_control : String?, new_module_path : String?, module_arguments_raw : String?) : Int32 | PluginResult
      unless new_type && new_control && new_module_path
        return PluginResult.new(changed: false, failed: true, msg: "state=#{state} requires new_type, new_control, and new_module_path")
      end
      if state == "before"
        insert_before(lines, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw)
      else
        insert_after(lines, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw)
      end
    end

    # Splits a single raw string into module-argument tokens the way
    # RULE_ARG_REGEX.findall does: whitespace-separated, but a
    # bracketed group stays whole.
    private def split_arg_tokens(s : String) : Array(String)
      tokens = [] of String
      s.scan(ARG_RE) { |match| tokens << match[0] unless match[0].empty? }
      tokens
    end

    # Parses a module_arguments param value. It arrives as a plain
    # String (per this codebase's param convention): either a
    # JSON-array-shaped string (a YAML list templated through) or a
    # bare string, which real Ansible's own `type: list` coercion
    # further comma-splits before this module's own whitespace
    # splitting runs.
    private def parse_module_arguments(raw : String?, return_none : Bool = false) : Array(String)?
      return (return_none ? nil : [] of String) if raw.nil?

      trimmed = raw.strip
      elements =
        if trimmed.starts_with?('[') && trimmed.ends_with?(']')
          (Array(String).from_json(trimmed) rescue nil) || [trimmed]
        elsif trimmed.includes?(',')
          trimmed.split(',').map(&.strip)
        else
          [trimmed]
        end

      return [] of String if elements.size == 1 && elements[0].empty?

      parsed = [] of String
      elements.each { |e| parsed.concat(split_arg_tokens(e)) }
      parsed
    end

    private def parse_lines(content : String) : Array(PamdRuleLine)
      raw_lines = content.split('\n')
      raw_lines.pop if raw_lines.last? == "" # trailing newline artifact

      raw_lines.map do |raw|
        stripped = raw.lstrip
        if stripped.starts_with?('#')
          PamdRuleLine.other(raw, :comment)
        elsif stripped.starts_with?("@include")
          PamdRuleLine.other(raw, :include)
        elsif raw.strip.empty?
          PamdRuleLine.other(raw, :empty)
        elsif m = RULE_RE.match(raw.strip)
          args = split_arg_tokens(m[4])
          PamdRuleLine.new(m[1], m[2], m[3], args)
        else
          PamdRuleLine.other(raw, :unparsed) # unparseable line - preserved verbatim, invalid per real's validate()
        end
      end
    end

    private def write(path : String, lines : Array(PamdRuleLine)) : Nil
      rendered = lines.map(&.to_s)
      marker = "# Updated by Ansible - #{Time.local.to_s("%Y-%m-%dT%H:%M:%S.%6N")}"
      if rendered.size <= 1
        rendered = ["", marker] + rendered
      elsif rendered[1].starts_with?("# Updated by Ansible")
        rendered[1] = marker
      else
        rendered = [rendered[0], marker] + rendered[1..]
      end
      File.write(path, rendered.join('\n') + '\n')
    end

    private def matching(lines : Array(PamdRuleLine), type : String, control : String, module_path : String) : Array(PamdRuleLine)
      lines.select(&.matches?(type, control, module_path))
    end

    private def update_rule(lines, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw) : Int32
      found = matching(lines, type, control, module_path)
      new_args = parse_module_arguments(module_arguments_raw, return_none: true)

      changes = 0
      found.each do |rule|
        changed = false
        if new_type && rule.rule_type != new_type
          rule.rule_type = new_type
          changed = true
        end
        if new_control && rule.control != new_control
          rule.control = PamdPlugin.normalize_control(new_control)
          changed = true
        end
        if new_module_path && rule.path != new_module_path
          rule.path = new_module_path
          changed = true
        end
        if !new_args.nil? && rule.args != new_args
          rule.args = new_args
          changed = true
        end
        changes += 1 if changed
      end
      changes
    end

    private def insert_before(lines, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw) : Int32
      new_args = parse_module_arguments(module_arguments_raw)
      changes = 0
      matching(lines, type, control, module_path).each do |rule|
        idx = lines.index(rule)
        next unless idx
        j = idx - 1
        while j >= 0 && (lines[j].kind == :comment || lines[j].kind == :empty)
          j -= 1
        end
        prev_rule = j >= 0 ? lines[j] : nil
        next if prev_rule && prev_rule.matches?(new_type, new_control, new_module_path)

        new_rule = PamdRuleLine.new(new_type, new_control, new_module_path, new_args || [] of String)
        lines.insert(idx, new_rule)
        changes += 1
      end
      changes
    end

    private def insert_after(lines, type, control, module_path, new_type, new_control, new_module_path, module_arguments_raw) : Int32
      new_args = parse_module_arguments(module_arguments_raw)
      changes = 0
      matching(lines, type, control, module_path).each do |rule|
        idx = lines.index(rule)
        next unless idx
        j = idx + 1
        while j < lines.size && (lines[j].kind == :comment || lines[j].kind == :empty)
          j += 1
        end
        next_rule = j < lines.size ? lines[j] : nil
        next if next_rule && next_rule.matches?(new_type, new_control, new_module_path)

        new_rule = PamdRuleLine.new(new_type, new_control, new_module_path, new_args || [] of String)
        lines.insert(idx + 1, new_rule)
        changes += 1
      end
      changes
    end

    private def add_module_arguments(lines, type, control, module_path, module_arguments_raw) : Int32
      to_add = parse_module_arguments(module_arguments_raw) || [] of String
      changes = 0

      matching(lines, type, control, module_path).each do |rule|
        simple_new = Set(String).new
        kv_new = Hash(String, String).new
        to_add.each do |arg|
          next if arg.starts_with?('[')
          if arg.includes?('=')
            k, v = arg.split('=', 2)
            kv_new[k] = v
          else
            simple_new << arg
          end
        end

        simple_cur = Set(String).new
        kv_cur = Hash(String, String).new
        rule.args.each do |arg|
          next if arg.starts_with?('[')
          if arg.includes?('=')
            k, v = arg.split('=', 2)
            kv_cur[k] = v
          else
            simple_cur << arg
          end
        end

        changed = false
        to_append = [] of String
        (simple_new - simple_cur).each { |arg| to_append << arg }
        (kv_new.keys.to_set - kv_cur.keys.to_set).each { |k| to_append << "#{k}=#{kv_new[k]}" }
        unless to_append.empty?
          rule.args = rule.args + to_append
          changed = true
        end

        (kv_new.keys.to_set & kv_cur.keys.to_set).each do |k|
          if kv_cur[k] != kv_new[k]
            idx = rule.args.index("#{k}=#{kv_cur[k]}")
            rule.args[idx] = "#{k}=#{kv_new[k]}" if idx
            changed = true
          end
        end

        changes += 1 if changed
      end
      changes
    end

    private def remove_module_arguments(lines, type, control, module_path, module_arguments_raw) : Int32
      to_remove = (parse_module_arguments(module_arguments_raw) || [] of String).to_set
      changes = 0
      matching(lines, type, control, module_path).each do |rule|
        next if (rule.args.to_set & to_remove).empty?
        rule.args = rule.args.reject { |arg| to_remove.includes?(arg) }
        changes += 1
      end
      changes
    end

    private def remove_matching(lines, type, control, module_path) : Int32
      found = matching(lines, type, control, module_path)
      found.each { |rule| lines.delete(rule) }
      found.size
    end

    # Returns the backup file path ("" when backup: yes wasn't given),
    # so #execute can echo it as the backupdest result field. Naming
    # matches real ansible's backup_local() helper (used by pamd's
    # backup): <path>.<file-owner-uid>.<YYYY-MM-DD@HH:MM:SS>~ -
    # live-verified against real ansible 2026-09-13.
    private def backup(path : String) : String
      return "" unless true?(@params["backup"]?)
      timestamp = Time.local.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{remote_exec("stat -c %u #{path}")[:stdout].strip}.#{timestamp}~"
      File.copy(path, backup_path)
      backup_path
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::PamdPlugin.new(config)
plugin.run

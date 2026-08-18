#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
    property kind : Symbol # :rule, :comment, :empty, :include
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
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      type = @params["type"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: type") unless type

      control = @params["control"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: control") unless control

      module_path = @params["module_path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: module_path") unless module_path

      state = @params["state"]? || "updated"
      dir = expand_tilde(@params["path"]? || "/etc/pam.d")
      path = File.join(dir, name)
      check_mode = is_true?(@params["check_mode"]?)

      unless File.exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "#{path} does not exist")
      end

      lines = parse_lines(File.read(path))

      changes = apply_state(lines, state, type, control, module_path)
      return changes if changes.is_a?(PluginResult)

      return PluginResult.new(changed: false, failed: false, msg: "No matching rule in #{path}") if changes == 0
      return PluginResult.new(changed: true, failed: false, msg: "Would update #{changes} rule(s) in #{path}") if check_mode

      backup(path)
      write(path, lines)
      PluginResult.new(changed: true, failed: false, msg: "Updated #{changes} rule(s) in #{path}")
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
        elsif m = RULE_RE.match(raw)
          args = split_arg_tokens(m[4])
          PamdRuleLine.new(m[1], m[2], m[3], args)
        else
          PamdRuleLine.other(raw, :comment) # unparseable line - preserve verbatim
        end
      end
    end

    private def write(path : String, lines : Array(PamdRuleLine))
      rendered = lines.map(&.to_s)
      marker = "# Updated by Ansible - #{Time.local}"
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

    private def backup(path : String)
      return unless is_true?(@params["backup"]?)
      timestamp = Time.local.to_s("%Y%m%d-%H%M%S")
      File.copy(path, "#{path}.#{timestamp}.bak")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::PamdPlugin.new(config)
plugin.run

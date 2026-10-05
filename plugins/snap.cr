#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # snap plugin - manages snap packages via the `snap` command, a
  # native reimplementation of community.general.snap.
  #
  # Implemented against real snap.py's control flow (StateModuleHelper):
  #   - `snap version` runs first (get_version) and its 2-token lines
  #     become the always-returned `version` dict
  #   - state=present resolves names via `snap info` (names_from_snaps);
  #     a name snap info cannot resolve crashes the real module with
  #     IndexError ("Module failed with exception: list index out of
  #     range") - reproduced here, including the "Snaps not found:"
  #     do_raise path when snapd emits its "warning: no snap found"
  #     lines
  #   - idempotency comes from a bare `snap list` parsed into
  #     (name, tracking-channel) pairs: NOT_INSTALLED installs,
  #     CHANNEL_MISMATCH refreshes (`snap refresh`), INSTALLED is a
  #     no-op - presence alone is not idempotent when `channel:` is
  #     given and the installed tracking channel differs
  #   - state=absent / enabled / disabled act via `_generic_state_action`
  #     (snaps_removed / snaps_enabled / snaps_disabled); enable of a
  #     snap that is not installed fails (is_snap_enabled returns None,
  #     `not None` is actionable) while disable of one silently no-ops -
  #     both quirks mirrored
  #   - `options:` runs `snap get -d` per actionable snap, compares
  #     against the flattened JSON map, and applies all changed pairs in
  #     one `snap set <name> k=v ...`
  #   - result shapes follow the module's VarDict output order, pinned
  #     byte-for-byte against the round-1100100 probe captures and
  #     local ansible-core 2.19.11 runs: success results carry no msg;
  #     `classic`/`channel` precede `version` in state=present results
  #     (order swapped to channel-then-classic when the task passes
  #     `channel:` at all - observed on both the real host and local
  #     runs); `cmd` is the Python repr of the param-name list plus the
  #     actionable names (joined with "; " per name when classic or a
  #     non-stable channel meets multiple snaps); module-crash failures
  #     carry the module_fails_on_exception skeleton
  #     [output, vars, <output vars>, failed, msg, changed, exception]
  #     with the output vars accumulated up to the crash point
  #   - check mode: discovery runs for real, mutating commands are not
  #     run (a not-installed snap still reports changed + snaps_installed
  #     without cmd, matching _present's check_mode return)
  #
  # `name:` accepts a comma/space-separated list (Ansible accepts a YAML
  # list or a comma-separated string; krikri flattens task params to
  # strings, so the string forms are what arrive here).
  class SnapPlugin < BasePlugin
    private SNAP_STATES = %w[absent present enabled disabled]

    # Real snap.py's names_from_snaps/retrieve_option_map IndexError text
    # (res[0] on empty parse output) - the observable failure for any
    # single snap name `snap info` cannot resolve.
    private CRASH_MSG = "Module failed with exception: list index out of range"

    private enum SnapStatus
      NotInstalled
      ChannelMismatch
      Installed
    end

    # Output vars accumulated in the real module's VarDict insertion
    # order - the key order of both success results and the crash
    # skeleton's output/vars objects.
    @out_vars = [] of Tuple(String, JSON::Any)
    @module_changed = false

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      name_param = @params["name"]?
      unless name_param
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: name")
      end
      names = name_param.split(/[\s,]+/).reject(&.empty?)

      state = @params["state"]? || "present"
      unless SNAP_STATES.includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: #{SNAP_STATES.join(", ")}, got: #{state}")
      end

      # Real snap.py requires the snap binary before any state check
      # of individual packages (get_bin_path(required=True) in its
      # setup).
      snap_bin = find_required_binary("snap")
      unless snap_bin
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("snap"))
      end

      classic = true?(@params["classic"]?)
      dangerous = true?(@params["dangerous"]?)
      channel_param = explicit_null_param?("channel") ? nil : @params["channel"]?

      version = get_version(snap_bin)
      set_out_var("version", version)

      case state
      when "present"
        resolved = names_from_snaps(snap_bin, names)
        return resolved if resolved.is_a?(PluginResult)
        set_out_var("snap_names", json_str_array(resolved))

        # set_meta("classic"/"channel", output=True) at state_present
        # entry makes both visible; the VarDict position order swaps to
        # channel-then-classic when the task passed channel: at all.
        if @params.has_key?("channel")
          @out_vars.unshift({"classic", JSON::Any.new(classic)})
          @out_vars.unshift({"channel", json_nullable_string(channel_param)})
        else
          @out_vars.unshift({"channel", json_nullable_string(channel_param)})
          @out_vars.unshift({"classic", JSON::Any.new(classic)})
        end

        status_map = snap_status_map(snap_bin, resolved, names, channel_param)
        return status_map if status_map.is_a?(PluginResult)

        actionable_refresh = [] of String
        actionable_install = [] of String
        names.each do |snap_name|
          status = status_map[snap_name]?
          # dict(zip(name, snap_status)) truncates when snap info
          # resolved fewer names than were given; the real module then
          # dies on the missing key with KeyError(name).
          unless status
            return fail_module("Module failed with exception: '#{snap_name}'")
          end
          case status
          when .channel_mismatch? then actionable_refresh << snap_name
          when .not_installed?    then actionable_install << snap_name
          end
        end

        if res = present_run(snap_bin, actionable_refresh, classic, dangerous, channel_param, refresh: true)
          return res
        end
        if res = present_run(snap_bin, actionable_install, classic, dangerous, channel_param, refresh: false)
          return res
        end
        if res = set_options(snap_bin, names, status_map, check_mode?)
          return res
        end
      when "absent"
        status_map = snap_status_map(snap_bin, names, names, nil)
        return status_map if status_map.is_a?(PluginResult)
        actionable = names.reject { |snap_name| status_map[snap_name].not_installed? }
        if res = generic_state_run(snap_bin, actionable, "snaps_removed", "remove")
          return res
        end
      when "enabled", "disabled"
        actionable = [] of String
        names.each do |snap_name|
          enabled = snap_enabled?(snap_bin, snap_name)
          return enabled if enabled.is_a?(PluginResult)
          if state == "enabled"
            actionable << snap_name unless enabled == true
          else
            actionable << snap_name if enabled == true
          end
        end
        key = state == "enabled" ? "snaps_enabled" : "snaps_disabled"
        verb = state == "enabled" ? "enable" : "disable"
        if res = generic_state_run(snap_bin, actionable, key, verb)
          return res
        end
      end

      order = ["changed"]
      @out_vars.each { |k, _| order << k }
      order << "failed"

      result = PluginResult.new(changed: @module_changed, failed: false)
      # StateModuleHelper's run() backfills output["failed"] = False on
      # every normal exit (unlike plain AnsibleModule modules), and
      # __quit_module__ defaults an absent channel to "stable".
      result.extra["failed_flag"] = JSON::Any.new(false)
      @out_vars.each do |k, v|
        if k == "channel" && channel_param.nil?
          result.extra[k] = JSON::Any.new("stable")
        else
          result.extra[k] = v
        end
      end
      result.key_order = order
      result
    end

    # `snap version` - dict of lines with exactly two whitespace tokens,
    # in output order (get_version).
    private def get_version(snap_bin : String) : JSON::Any
      result = remote_exec("#{snap_bin} version")
      pairs = Hash(String, String).new
      result[:stdout].each_line do |line|
        tokens = line.split
        pairs[tokens[0]] = tokens[1] if tokens.size == 2
      end
      JSON.parse(pairs.to_json)
    end

    # names_from_snaps: state=present resolves `name:` (possibly a .snap
    # file's real name) via `snap info`. Single-name runs check stderr
    # for snapd's "warning: no snap found" lines, multi-name runs check
    # stdout; unresolved names crash the real module (IndexError).
    private def names_from_snaps(snap_bin : String, names : Array(String)) : Array(String) | PluginResult
      if names.size == 1
        name = names[0]
        result = remote_exec("#{snap_bin} info #{Shell.single_quote(name)}")
        if result[:stderr].includes?("warning: no snap found")
          not_found = snaps_not_found_from_out(result[:stdout])
          return fail_module("Snaps not found: #{py_list(not_found)}.")
        end
        line = result[:stdout].lines.find { |candidate| candidate.starts_with?("name:") }
        return fail_module(CRASH_MSG) unless line
        return [line.split[1]]
      end

      result = remote_exec("#{snap_bin} info #{names.map { |each_name| Shell.single_quote(each_name) }.join(' ')}")
      if result[:stdout].includes?("warning: no snap found")
        not_found = snaps_not_found_from_out(result[:stdout])
        return fail_module("Snaps not found: #{py_list(not_found)}.")
      end
      resolved = [] of String
      result[:stdout].split("\n---").each do |section|
        line = section.lines.find { |candidate| candidate.starts_with?("name:") }
        return fail_module(CRASH_MSG) unless line
        resolved << line.split[1]
      end
      resolved
    end

    private def snaps_not_found_from_out(stdout : String) : Array(String)
      stdout.lines.select(&.starts_with?("warning: no snap found")).map { |warning_line| warning_line.split[-1] }
    end

    # snap_status: bare `snap list` parsed into (name, tracking channel)
    # pairs (its rc is ignored, as observed on the real module), then
    # NOT_INSTALLED / CHANNEL_MISMATCH / INSTALLED per name. The statuses
    # are computed over the RESOLVED names but zipped back onto the
    # original ones (dict(zip(name, snap_status))).
    private def snap_status_map(snap_bin : String, status_names : Array(String), original_names : Array(String), channel_param : String?) : Hash(String, SnapStatus) | PluginResult
      result = remote_exec("#{snap_bin} list")
      installed = [] of Tuple(String, String)
      result[:stdout].lines.skip(1).each do |line|
        tokens = line.split
        installed << {tokens[0], tokens[3]} if tokens.size >= 4
      end

      statuses = status_names.map do |name|
        match = installed.find { |listed, _| listed == name }
        if match.nil?
          SnapStatus::NotInstalled
        elsif channel_param && !{channel_param, "latest/#{channel_param}"}.includes?(match[1])
          SnapStatus::ChannelMismatch
        else
          SnapStatus::Installed
        end
      end

      map = Hash(String, SnapStatus).new
      original_names.each_with_index do |name, i|
        map[name] = statuses[i]? || SnapStatus::NotInstalled
      end
      map
    end

    # state_present's _present: one actionable group, install or refresh.
    private def present_run(snap_bin : String, actionable : Array(String), classic : Bool, dangerous : Bool, channel_param : String?, refresh : Bool) : PluginResult?
      return nil if actionable.empty?

      @module_changed = true
      set_out_var("snaps_installed", json_str_array(actionable))
      return nil if check_mode?

      params_list = ["state", "classic", "channel", "dangerous"]
      has_one_pkg_params = classic || channel_param != "stable"
      verb = refresh ? "refresh" : "install"

      cmd_repr : String
      exit_code : Int32
      stderr : String
      if has_one_pkg_params && actionable.size > 1
        parts = [] of String
        first_rc = 0
        errs = [] of String
        actionable.each do |name|
          result = remote_exec(install_command(snap_bin, verb, classic, dangerous, channel_param, [name]))
          parts << py_list(params_list + [name])
          first_rc = result[:exit_code] if first_rc == 0 && result[:exit_code] != 0
          errs << result[:stderr].strip
        end
        cmd_repr = parts.join("; ")
        exit_code = first_rc
        stderr = errs.join("\n")
      else
        result = remote_exec(install_command(snap_bin, verb, classic, dangerous, channel_param, actionable))
        cmd_repr = py_list(params_list + actionable)
        exit_code = result[:exit_code]
        stderr = result[:stderr].strip
      end
      set_out_var("cmd", JSON::Any.new(cmd_repr))

      return nil if exit_code == 0

      classic_match = stderr.match(/^error: This revision of snap "(\w+)" was published using classic confinement/)
      msg = if m = classic_match
              "Couldn't install #{m[1]} because it requires classic confinement"
            else
              "Ooops! Snap installation failed while executing '#{cmd_repr}', " \
              "please examine logs and error output for more details."
            end
      fail_module(msg)
    end

    private def install_command(snap_bin : String, verb : String, classic : Bool, dangerous : Bool, channel_param : String?, names : Array(String)) : String
      cmd = "#{snap_bin} #{verb}"
      cmd += " --classic" if classic
      # as_func: no --channel at all when the value is "stable"
      cmd += " --channel #{Shell.single_quote(channel_param)}" if channel_param && channel_param != "stable"
      cmd += " --dangerous" if dangerous
      cmd + " " + names.map { |each_name| Shell.single_quote(each_name) }.join(' ')
    end

    # _generic_state_action: absent/enable/disable.
    private def generic_state_run(snap_bin : String, actionable : Array(String), out_key : String, verb : String) : PluginResult?
      return nil if actionable.empty?

      @module_changed = true
      set_out_var(out_key, json_str_array(actionable))
      return nil if check_mode?

      cmd_repr = py_list(["classic", "channel", "state"] + actionable)
      set_out_var("cmd", JSON::Any.new(cmd_repr))
      result = remote_exec("#{snap_bin} #{verb} #{actionable.map { |each_name| Shell.single_quote(each_name) }.join(' ')}")
      return nil if result[:exit_code] == 0

      fail_module("Ooops! Snap operation failed while executing '#{cmd_repr}', " \
                  "please examine logs and error output for more details.")
    end

    # is_snap_enabled: `snap list <name>` notes column. rc != 0 means
    # "unknown" (None); a too-short listing crashes the real module with
    # IndexError, an unparseable line raises its own message.
    private def snap_enabled?(snap_bin : String, name : String) : Bool? | PluginResult
      result = remote_exec("#{snap_bin} list #{Shell.single_quote(name)}")
      return nil if result[:exit_code] != 0

      lines = result[:stdout].lines
      return fail_module(CRASH_MSG) if lines.size < 2
      tokens = lines[1].split
      unless tokens.size >= 6
        return fail_module("Unable to parse 'snap list #{name}' output:\n#{result[:stdout]}")
      end
      !tokens[5].split(",").includes?("disabled")
    end

    # set_options: only for state=present snaps that are installed;
    # `snap get -d` JSON flattened to a dotted key map, all changed pairs
    # applied in one `snap set <name> k=v ...`.
    private def set_options(snap_bin : String, names : Array(String), status_map : Hash(String, SnapStatus), check_mode : Bool) : PluginResult? # ameba:disable Metrics/CyclomaticComplexity
      options_param = @params["options"]? || return nil
      options = options_param.split(',').map(&.strip).reject(&.empty?)
      return nil if options.empty?

      overall_changed = [] of String
      names.each do |snap_name|
        next if status_map[snap_name]? == SnapStatus::NotInstalled

        option_map = retrieve_option_map(snap_bin, snap_name)
        return option_map if option_map.is_a?(PluginResult)

        changed_pairs = [] of String
        options.each do |option_string|
          eq = option_string.index('=')
          # __set_param_re: (?P<snap_prefix>\S+:)?(?P<key>\S+)\s*=\s*(?P<value>.+)
          # - no '=' at all, an empty value (.+ needs one char), or a key
          # side that carries a space inside the key token cannot match.
          unless eq && eq > 0 && option_string.size > eq + 1
            return fail_module("Cannot parse set option '#{option_string}'")
          end
          key_side = option_string[0...eq].rstrip
          if key_side.empty? || key_side.includes?(' ')
            return fail_module("Cannot parse set option '#{option_string}'")
          end
          value = option_string[(eq + 1)..].strip
          selected_snap_name = nil
          key = key_side
          if colon = key_side.rindex(':')
            suffix = key_side[(colon + 1)..]
            unless suffix.empty?
              selected_snap_name = key_side[0...colon]
              key = suffix
            end
          end
          if selected_snap_name && !names.includes?(selected_snap_name)
            return fail_module("Snap option '#{option_string}' refers to snap which is not in the list of snap names")
          end
          next unless selected_snap_name.nil? || selected_snap_name == snap_name

          if !option_map.has_key?(key) || option_map[key] != value
            changed_pairs << "#{key}=#{value}"
            overall_changed << (selected_snap_name ? option_string : "#{snap_name}:#{option_string}")
          end
        end

        next if changed_pairs.empty?
        @module_changed = true
        next if check_mode

        result = remote_exec("#{snap_bin} set #{Shell.single_quote(snap_name)} #{changed_pairs.map { |pair| Shell.single_quote(pair) }.join(' ')}")
        next if result[:exit_code] == 0

        err = result[:stderr].strip
        if err.includes?("has no \"configure\" hook")
          return fail_module("Snap '#{snap_name}' does not have any configurable options")
        end
        return fail_module("Cannot set options '#{changed_pairs.join(' ')}' for snap '#{snap_name}': error=#{err}")
      end

      set_out_var("options_changed", json_str_array(overall_changed)) unless overall_changed.empty?
      nil
    end

    # retrieve_option_map: `snap get -d <name>`; rc != 0 or snapd's
    # "has no configuration" line means an empty map; empty output
    # crashes the real module (result[0] IndexError); unparseable JSON
    # raises with the json.loads error text.
    private def retrieve_option_map(snap_bin : String, snap_name : String) : Hash(String, String) | PluginResult
      result = remote_exec("#{snap_bin} get -d #{Shell.single_quote(snap_name)}")
      return Hash(String, String).new if result[:exit_code] != 0

      lines = result[:stdout].lines
      return fail_module(CRASH_MSG) if lines.empty?
      return Hash(String, String).new if lines[0].includes?("has no configuration")

      begin
        parsed = JSON.parse(result[:stdout])
        map = Hash(String, String).new
        flatten_option_map(parsed, nil, map)
        map
      rescue e : OptionMapError
        fail_module(e.message || "Option map parsing failed")
      rescue
        fail_module("Parsing option map returned by 'snap get #{snap_name}' triggers exception " \
                    "'Expecting value: line 1 column 1 (char 0)', output:\n'#{result[:stdout]}'")
      end
    end

    # Mirrors convert_json_subtree_to_map's do_raise for non-dict leaves
    # and the json.loads failure for unparseable output.
    private class OptionMapError < Exception; end

    private def flatten_option_map(subtree : JSON::Any, prefix : String?, map : Hash(String, String)) : Nil
      obj = subtree.as_h?
      unless obj
        raise OptionMapError.new("Non-dict non-leaf element encountered while parsing option map. " \
                                 "The output format of 'snap set' may have changed. Aborting!")
      end
      obj.each do |key, value|
        full_key = prefix ? "#{prefix}.#{key}" : key
        if value.as_h?
          flatten_option_map(value, full_key, map)
        else
          map[full_key] = python_str(value)
        end
      end
    end

    # Python str() of a JSON leaf: True/False capitalized, floats keep a
    # decimal point.
    private def python_str(value : JSON::Any) : String
      case raw = value.raw
      when Bool    then raw ? "True" : "False"
      when Float64 then raw.to_s
      when Int64   then raw.to_s
      when String  then raw
      else              raw.to_s
      end
    end

    # The module_fails_on_exception failure shape: fail_json(msg=,
    # exception=, output=self.output, vars=self.vars.output(), **output)
    # - output and vars hold the same accumulated output dict, the
    # spread repeats its keys at top level, then fail_json's own
    # failed/msg/changed/exception follow.
    private def fail_module(msg : String) : PluginResult
      order = ["output", "vars"]
      @out_vars.each { |k, _| order << k }
      order << "failed"
      order << "msg"
      order << "changed"
      order << "exception"

      out_obj = obj_from_pairs(@out_vars)
      result = PluginResult.new(changed: false, failed: true, msg: msg)
      result.extra["output"] = out_obj
      result.extra["vars"] = out_obj
      @out_vars.each { |k, v| result.extra[k] = v }
      result.key_order = order
      result
    end

    private def check_mode? : Bool
      true?(@params["_ansible_check_mode"]?)
    end

    private def set_out_var(key : String, value : JSON::Any) : Nil
      index = @out_vars.index { |k, _| k == key }
      if index
        @out_vars[index] = {key, value}
      else
        @out_vars.push({key, value})
      end
    end

    private def obj_from_pairs(pairs : Array(Tuple(String, JSON::Any))) : JSON::Any
      hash = Hash(String, JSON::Any).new
      pairs.each { |k, v| hash[k] = v }
      JSON.parse(hash.to_json)
    end

    private def json_str_array(items : Array(String)) : JSON::Any
      JSON.parse(items.to_json)
    end

    private def json_nullable_string(value : String?) : JSON::Any
      value ? JSON::Any.new(value) : JSON::Any.new(nil)
    end

    # Python repr of a list of strings: single quotes, comma + space.
    private def py_list(items : Array(String)) : String
      "[" + items.map { |item| py_str(item) }.join(", ") + "]"
    end

    private def py_str(s : String) : String
      if s.includes?('\'')
        "\"#{s.gsub("\\", "\\\\").gsub('"', "\\\"")}\""
      else
        "'#{s}'"
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SnapPlugin.new(config)
plugin.run

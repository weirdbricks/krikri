#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # snap plugin - manages snap packages via the `snap` command, a
  # native port of community.general.snap.
  #
  # Implemented against real snap.py's control flow:
  #   - discovery via `snap list <name>` per name (exit code 0 =
  #     installed; real uses the same command and treats "not
  #     installed"/exit 64 output as absent)
  #   - install via `snap install <name>` (+ `--classic`, +
  #     `--channel <c>`; `--jailmode` not implemented - no tested
  #     caller), remove via `snap remove <name>`, disable/enable via
  #     `snap disable|enable <name>`
  #   - `options:` (space/comma-separated key=value pairs) applied via
  #     `snap set <name> <key=value>...` after install only (matching
  #     real's post-install set), and compared against
  #     `snap get <name> <key>` for idempotency
  #   - state: enabled/disabled inspect the Notes column of
  #     `snap list <name>` (real parses the same output; a disabled
  #     snap shows "disabled" in its notes)
  #   - check mode: discovery runs for real, mutating commands are not
  #     run (changed verdict still reported)
  #
  # `name:` accepts a comma/space-separated list (real accepts a YAML
  # list or a comma-separated string; krikri flattens task params to
  # strings, so the string forms are what arrive here).
  class SnapPlugin < BasePlugin
    private SNAP_STATES = %w[present absent enabled disabled]

    def execute : PluginResult
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

      if @params["channel"]?
        unless state == "present"
          return PluginResult.new(changed: false, failed: true,
            msg: "channel is supported only when state is present")
        end
      end

      # Real snap.py requires the snap binary before any state check
      # of individual packages (get_bin_path(required=True) in its
      # setup).
      snap_bin = find_snap_binary
      unless snap_bin
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to find required executable \"snap\" in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      classic = true?(@params["classic"]?)

      run = SnapRun.new

      names.each do |name|
        listing = snap_info(snap_bin, name)
        if listing.is_a?(String)
          return PluginResult.new(changed: false, failed: true, msg: listing)
        end

        if failure = apply_snap_state(snap_bin, name, state, classic, listing, check_mode, run)
          return failure
        end
      end

      PluginResult.new(changed: run.changed?, failed: false,
        msg: run.msgs.empty? ? "" : "snaps changed: #{run.msgs.join(", ")}")
    end

    private class SnapRun
      property? changed : Bool = false
      property msgs : Array(String) = [] of String
    end

    private def apply_snap_state(snap_bin : String, name : String, state : String, classic : Bool, listing : String?, check_mode : Bool, run : SnapRun) : PluginResult?
      case state
      when "absent"
        remove_snap(snap_bin, name, listing, check_mode, run)
      when "present"
        install_snap(snap_bin, name, classic, listing, check_mode, run)
      when "enabled", "disabled"
        toggle_snap(snap_bin, name, state, listing, check_mode, run)
      end
    end

    private def remove_snap(snap_bin : String, name : String, listing : String?, check_mode : Bool, run : SnapRun) : PluginResult?
      return nil unless listing
      return PluginResult.new(changed: true, failed: false,
        msg: "snap #{name} would be removed") if check_mode
      result = remote_exec("#{snap_bin} remove #{Shell.single_quote(name)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "could not remove snap #{name}: #{result[:stderr].strip}")
      end
      run.changed = true
      run.msgs << "#{name} removed"
      nil
    end

    private def install_snap(snap_bin : String, name : String, classic : Bool, listing : String?, check_mode : Bool, run : SnapRun) : PluginResult?
      if listing.nil?
        return PluginResult.new(changed: true, failed: false,
          msg: "snap #{name} would be installed") if check_mode
        cmd = "#{snap_bin} install"
        cmd += " --classic" if classic
        if channel = @params["channel"]?
          cmd += " --channel #{Shell.single_quote(channel)}"
        end
        cmd += " #{Shell.single_quote(name)}"
        result = remote_exec(cmd)
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "could not install snap #{name}: #{result[:stderr].strip}")
        end
        run.changed = true
        run.msgs << "#{name} installed"
      end
      if opt_changed = apply_options(snap_bin, name, check_mode)
        return PluginResult.new(changed: false, failed: true, msg: opt_changed) if opt_changed.is_a?(String)
        run.changed = true
      end
      nil
    end

    private def toggle_snap(snap_bin : String, name : String, state : String, listing : String?, check_mode : Bool, run : SnapRun) : PluginResult?
      unless listing
        return PluginResult.new(changed: false, failed: true,
          msg: "snap #{name} is not installed, cannot change its state to #{state}")
      end
      is_disabled = listing.includes?("disabled")
      want_disabled = state == "disabled"
      if is_disabled != want_disabled
        return PluginResult.new(changed: true, failed: false,
          msg: "snap #{name} would be #{state}") if check_mode
        verb = want_disabled ? "disable" : "enable"
        result = remote_exec("#{snap_bin} #{verb} #{Shell.single_quote(name)}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "could not #{verb} snap #{name}: #{result[:stderr].strip}")
        end
        run.changed = true
        run.msgs << "#{name} #{state}"
      end
      nil
    end

    private def find_snap_binary : String?
      result = remote_exec("command -v snap")
      result[:exit_code] == 0 && !result[:stdout].strip.empty? ? result[:stdout].strip : nil
    end

    # `snap list <name>`: returns the listing line (name + fields,
    # including Notes) when installed, nil when not, or an error
    # message string when snap itself fails some other way.
    private def snap_info(snap_bin : String, name : String) : String? | String
      result = remote_exec("#{snap_bin} list #{Shell.single_quote(name)} 2>/dev/null")
      return nil unless result[:exit_code] == 0

      lines = result[:stdout].lines
      return result[:stdout] if lines.size < 2
      lines[1]
    end

    # Applies `options:` (comma/space-separated key=value pairs) via
    # `snap set`, skipping pairs whose current `snap get` value already
    # matches. Returns true if anything changed, false otherwise, or
    # an error message string.
    private def apply_options(snap_bin : String, name : String, check_mode : Bool) : Bool | String?
      options_param = @params["options"]? || return false
      pairs = options_param.split(/[\s,]+/).reject(&.empty?)
      return false if pairs.empty?

      changed = false
      pairs.each do |pair|
        key, value = pair.split('=', 2)
        next unless value

        get_result = remote_exec("#{snap_bin} get #{Shell.single_quote(name)} #{Shell.single_quote(key)} 2>/dev/null")
        current = get_result[:exit_code] == 0 ? get_result[:stdout].strip : nil
        next if current == value.strip

        return true if check_mode
        result = remote_exec("#{snap_bin} set #{Shell.single_quote(name)} #{Shell.single_quote(pair)}")
        unless result[:exit_code] == 0
          return "could not set option #{key} for snap #{name}: #{result[:stderr].strip}"
        end
        changed = true
      end
      changed
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SnapPlugin.new(config)
plugin.run

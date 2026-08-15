#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # pamd plugin - edits a /etc/pam.d/<name> service config. Compatible
  # (for the parameters implemented here) with Ansible's community.
  # general.pamd module.
  #
  # A PAM config line has the shape `TYPE CONTROL MODULE_PATH
  # [MODULE_ARGUMENTS]`.
  #
  # Supported parameters:
  # - name (required): the /etc/pam.d/ file, without the directory
  # - type (required): auth/account/password/session
  # - control (required for state: present): simple control value
  #   ("optional", "required", ...) - the bracketed `[success=1
  #   default=ignore]` form isn't parsed/matched specially, just
  #   compared as a literal string
  # - module_path (required)
  # - module_arguments: appended verbatim after module_path
  # - state: present (default) / absent
  # - path: PAM config directory (default /etc/pam.d)
  # - backup: bool - write a timestamped copy before changing
  # - check_mode
  #
  # state: absent removes every line matching type + module_path (and
  # control, if given) exactly. state: present appends a new line
  # built from type/control/module_path/module_arguments unless a line
  # already matching all four already exists.
  #
  # Not implemented: state: updated/before/after (repositioning or
  # editing an existing rule's control/arguments in place - real
  # Ansible's own default state) - konstruktoid/ansible-role-hardening's
  # own only real caller uses state: absent. new_type:/new_control:/
  # new_module_path: (updated:'s own rename fields).
  class PamdPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      type = @params["type"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: type") unless type

      module_path = @params["module_path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: module_path") unless module_path

      state = @params["state"]? || "present"
      dir = expand_tilde(@params["path"]? || "/etc/pam.d")
      path = File.join(dir, name)
      check_mode = is_true?(@params["check_mode"]?)

      unless File.exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "#{path} does not exist")
      end

      lines = File.read_lines(path)

      case state
      when "absent"
        ensure_absent(path, lines, type, @params["control"]?, module_path, check_mode)
      when "present"
        control = @params["control"]?
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: control") unless control
        ensure_present(path, lines, type, control, module_path, @params["module_arguments"]?, check_mode)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}' (state: updated/before/after are not implemented)")
      end
    end

    private def matches?(line : String, type : String, control : String?, module_path : String)
      fields = line.strip.split(/\s+/)
      return false if fields.size < 3
      return false unless fields[0] == type
      return false if control && fields[1] != control
      fields[2] == module_path
    end

    private def ensure_absent(path : String, lines : Array(String), type : String, control : String?, module_path : String, check_mode : Bool) : PluginResult
      kept = lines.reject { |line| matches?(line, type, control, module_path) }
      return PluginResult.new(changed: false, failed: false, msg: "No matching rule in #{path}") if kept.size == lines.size
      return PluginResult.new(changed: true, failed: false, msg: "Would remove rule from #{path}") if check_mode

      backup(path)
      File.write(path, kept.join('\n') + '\n')
      PluginResult.new(changed: true, failed: false, msg: "Removed rule from #{path}")
    end

    private def ensure_present(path : String, lines : Array(String), type : String, control : String, module_path : String, module_arguments : String?, check_mode : Bool) : PluginResult
      already = lines.any? { |line| matches?(line, type, control, module_path) }
      return PluginResult.new(changed: false, failed: false, msg: "Rule already present in #{path}") if already
      return PluginResult.new(changed: true, failed: false, msg: "Would add rule to #{path}") if check_mode

      new_line = String.build do |line|
        line << type << "\t" << control << "\t" << module_path
        line << " " << module_arguments if module_arguments
      end

      backup(path)
      File.write(path, (lines + [new_line]).join('\n') + '\n')
      PluginResult.new(changed: true, failed: false, msg: "Added rule to #{path}")
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

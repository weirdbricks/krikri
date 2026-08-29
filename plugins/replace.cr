#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Replace Plugin - Replace each regex match in a file with a replacement
  # string, matching ansible.builtin.replace semantics.
  #
  # Parameters:
  #   path (required): File to operate on
  #   regexp (required): Regex pattern to match
  #   replace (optional): Replacement string (default: empty, i.e. delete
  #     matches). `\1`, `\2` etc. are backreferences to capture groups.
  #   owner/group/mode (optional): attribute changes to apply
  #   check_mode (optional): Dry-run mode
  #
  # Only rewrites the file when the substitution actually changes its
  # contents (idempotent), matching real Ansible: a "changed" result means
  # the file was modified, and re-running with no remaining matches reports
  # changed: false. Real Ansible fails if the file doesn't exist.
  class ReplacePlugin < BasePlugin
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # path (aliases: dest, name) - matches real Ansible's own
      # argument_spec, where `dest:` is the long-standing legacy alias
      # most existing playbooks/roles still write (lineinfile.cr already
      # supports the same three spellings). Found via konstruktoid-
      # hardening's own "Set default bash.bashrc umask" task, which uses
      # `dest:` - "Missing required parameter: path" even though the
      # task supplied a perfectly valid (if not the newest-spelling)
      # target file parameter.
      path = @params["path"]? || @params["dest"]? || @params["name"]?
      unless path
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: path"
        )
      end
      path = expand_tilde(path)

      pattern = @params["regexp"]?
      unless pattern
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: regexp"
        )
      end

      # Real Ansible's replace fails if the file doesn't exist (no `creates`
      # tolerance), and that failure isn't recoverable without the file
      # appearing - so it raises rather than silently no-op'ing.
      unless File.exists?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path #{path} does not exist"
        )
      end

      begin
        content = File.read(path)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read #{path}: #{ex.message}"
        )
      end

      replace = @params["replace"]? || ""

      regex = begin
        Regex.new(pattern)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid regular expression: #{ex.message}"
        )
      end

      new_content = content.gsub(regex, replace)
      changed = new_content != content

      if @check_mode
        msg = changed ? "Would replace matches in #{path}" : "No matches to replace in #{path}"
        return PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          path: path
        )
      end

      if changed
        begin
          File.write(path, new_content)
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to write #{path}: #{ex.message}"
          )
        end
      end

      # Apply any requested attribute changes (owner/group/mode), matching
      # real Ansible which also sets them even on a no-matches run.
      attr_changed = apply_attributes(path)

      PluginResult.new(
        changed: changed || attr_changed,
        failed: false,
        msg: changed ? "Replaced matches in #{path}" : "No matches to replace in #{path}",
        path: path
      )
    end

    # Applies mode if given; returns whether it changed. owner/group would
    # require resolving a name to uid/gid (getpwnam), which is only
    # meaningful for the local user of a local connection - the role's
    # replace tasks (os_hardening's yum gpgcheck) only request mode.
    private def apply_attributes(path : String) : Bool
      changed = false
      mode = @params["mode"]?
      return false unless mode

      begin
        target = mode.to_i(8)
        current = File.info(path).permissions.value & 0o777
        unless current == target
          File.chmod(path, target)
          changed = true
        end
      end
      changed
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::ReplacePlugin.new(config)
plugin.run

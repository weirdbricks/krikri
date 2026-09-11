#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/kernel_blacklist_file"

module Krikri
  # kernel_blacklist plugin (community.general.kernel_blacklist) -
  # adds/removes `blacklist <module>` entries in a modprobe.d file.
  #
  # Pure file editing - the real module never touches modprobe itself
  # (blacklisting only affects the NEXT probe/load, never an
  # already-loaded module), so neither does this. Params:
  # - name: required. Kernel module name.
  # - state: present (default) / absent.
  # - blacklist_file: target file, default
  #   /etc/modprobe.d/blacklist-ansible.conf (the real module's own
  #   default - not the historical /etc/modprobe.d/blacklist.conf).
  #
  # Mirrors the real module's file handling exactly: a missing file is
  # created (even in check mode - the real module's init runs the
  # creation before any check-mode gate), entries match
  # `^blacklist\s+<name>$` on stripped non-comment lines, and a
  # newly-created file counts as a change on its own (state=absent
  # against a missing file still reports changed=true, since the file
  # got created).
  class KernelBlacklistPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      state = @params["state"]? || "present"
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: present, absent, got #{state}")
      end

      file = @params["blacklist_file"]? || "/etc/modprobe.d/blacklist-ansible.conf"
      check_mode = true?(@params["check_mode"]?)

      file_existed = File.exists?(file)
      lines = file_existed ? File.read_lines(file).map(&.rchop) : nil

      new_lines, changed = PluginHelpers::KernelBlacklistFile.apply(lines, name, state)

      if changed && !check_mode
        parent = File.dirname(file)
        Dir.mkdir_p(parent) unless Dir.exists?(parent)
        File.write(file, new_lines.empty? ? "" : new_lines.map { |l| l + "\n" }.join)
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: file_existed ? "" : "created #{file}",
      )
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::KernelBlacklistPlugin.new(config)
plugin.run

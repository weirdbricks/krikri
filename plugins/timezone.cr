#!/usr/bin/env crystal

# timezone module (community.general.timezone) - sets the system timezone.
#
# Entirely unimplemented before - `robertdebock.locale`'s own "Set
# timezone" task (`community.general.timezone: name: "{{ locale_timezone
# }}"`) silently skipped with "Plugin not available" while real Ansible
# actually changed the timezone.
#
# Real Ansible's module supports several OS-specific backends (systemd/
# timedatectl, SmartOS, macOS, BSD, AIX) plus a non-systemd Linux fallback
# editing /etc/timezone + /etc/localtime directly. Every target this repo
# benchmarks against is systemd-based (Ubuntu 22.04+), so only the
# `SystemdTimezone` backend (`timedatectl show`/`timedatectl set-timezone`)
# is implemented here - matches real Ansible's own class-selection logic,
# which picks that backend whenever `timedatectl` exists and is usable.
# `hwclock:` (RTC local-vs-UTC) is a separate, rarer param no role
# benchmarked so far uses - not implemented; only `name:`.

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class TimezonePlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      check_mode = is_true?(@params["check_mode"]?)

      current = current_timezone
      if current == name
        return PluginResult.new(changed: false, failed: false, msg: "OK")
      end

      if check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "would set timezone to #{name} (executed `timedatectl set-timezone`)",
          diff: generate_attribute_diff({"name" => current}, {"name" => name}),
        )
      end

      output = IO::Memory.new
      status = Process.run("timedatectl", ["set-timezone", name], output: output, error: output)
      unless status.success?
        return PluginResult.new(changed: false, failed: true, msg: "timedatectl set-timezone failed: #{output.to_s.strip}")
      end

      PluginResult.new(
        changed: true,
        failed: false,
        msg: "executed `timedatectl set-timezone #{name}`",
        diff: generate_attribute_diff({"name" => current}, {"name" => name}),
      )
    end

    # `timedatectl show -p Timezone --value` prints just the bare zone
    # name (e.g. "Etc/UTC") with no parsing needed - simpler and more
    # robust than real Ansible's own `timedatectl status` regex scrape,
    # while returning the exact same value for the same underlying state.
    private def current_timezone : String
      output = IO::Memory.new
      Process.run("timedatectl", ["show", "-p", "Timezone", "--value"], output: output, error: Process::Redirect::Close)
      output.to_s.strip
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::TimezonePlugin.new(config)
plugin.run

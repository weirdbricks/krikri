#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/gem_command"

module CrystalPlay
  # Gem plugin - manages Ruby gems via the `gem` CLI. Compatible with (a
  # subset of) Ansible's community.general.gem module - real Ansible's
  # own module also just shells out to the `gem` command line tool
  # internally, not a Ruby API, so this mirrors that approach rather
  # than being a compromise.
  #
  # Real gap found benchmarking geerlingguy.ruby's own "Install
  # Bundler."/"Install configured gems." tasks, and geerlingguy.fluentd's
  # "Ensure Fluentd plugins are installed." (a custom `executable:`
  # pointing at td-agent's own bundled fluent-gem) - entirely
  # unimplemented before (no plugins/gem.cr at all, not in
  # AVAILABLE_PLUGINS), so every real playbook's gem: task was skipped
  # outright ("Plugin not available"), silently never installing
  # anything.
  #
  # Supported parameters:
  # - name (required): a gem name
  # - state: present (default) | absent | latest
  # - version: exact version to install
  # - executable: which `gem` binary to use (default: "gem" via PATH -
  #   fluentd's own td-agent-bundled fluent-gem is a real example of
  #   overriding this)
  # - user_install: install to the user's local gem dir via
  #   `--user-install` (default true, matching real Ansible's own
  #   default) rather than system-wide
  # - bindir: custom `--bindir` for installed executables
  #
  # Idempotency: `present` (no version:) checks `gem list -i "^name$"`
  # for existence at ANY version - already installed is a no-op,
  # matching real Ansible's own default behavior. `present` with a
  # version: checks that specific version via `-v`. `latest` always
  # invokes `gem install`, matching real Ansible's own GemModule
  # (a fresh `gem install` on an already-latest gem is a real no-op at
  # the `gem` CLI level, but this module doesn't attempt to distinguish
  # that from a real upgrade in its own changed: reporting - narrower
  # than pip.cr's own state: latest handling, revisit if a real
  # playbook needs it).
  #
  # - repository: `--source <repository>`
  # - include_dependencies: default true (matching real Ansible's own
  #   default exactly - NOT false) - only ever adds a flag
  #   (`--ignore-dependencies`) when explicitly set false; true adds
  #   nothing (modern rubygems installs dependencies by default with no
  #   flag needed)
  # - norc: `--norc` - real Ansible gates this on the installed rubygems
  #   version being >= 2.5.2; not replicated here (a rubygems that old
  #   predates any real playbook this project has benchmarked against by
  #   a decade-plus) - always added when requested
  #
  # Verified against real community.general gem.py's own `install`/
  # `uninstall`/`common_opts` source directly (flag order included), via
  # a new pure `PluginHelpers::GemCommand`.
  #
  # Not implemented: `pre_release:`, `gem_source:` (local .gem file
  # installs), `force:`.
  class GemPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "name is required") unless name

      state = @params["state"]? || "present"
      executable = @params["executable"]? || "gem"
      version = @params["version"]?

      case state
      when "absent"
        remove(executable, name, version)
      when "latest"
        install(executable, name, version, force: true)
      else
        install(executable, name, version, force: false)
      end
    end

    private def installed?(executable : String, name : String, version : String?) : Bool
      cmd = "#{executable} list -i \"^#{name}$\""
      cmd += " -v \"#{version}\"" if version
      remote_exec(cmd)[:exit_code] == 0
    end

    private def install(executable : String, name : String, version : String?, force : Bool) : PluginResult
      unless force
        return PluginResult.new(changed: false, failed: false, msg: "Gem already installed") if installed?(executable, name, version)
      end

      user_install = @params["user_install"]?.nil? || true?(@params["user_install"]?)
      bindir = @params["bindir"]?
      include_dependencies = @params["include_dependencies"]?.nil? || true?(@params["include_dependencies"]?)

      cmd = PluginHelpers::GemCommand.install_command(
        executable, name, version, user_install, bindir,
        @params["repository"]?, include_dependencies, true?(@params["norc"]?)
      )

      result = remote_exec(cmd)
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to install gem: #{result[:stderr]}", stdout: result[:stdout], stderr: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Gem installed", stdout: result[:stdout])
    end

    private def remove(executable : String, name : String, version : String?) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Gem already absent") unless installed?(executable, name, version)

      result = remote_exec(PluginHelpers::GemCommand.uninstall_command(executable, name, version, true?(@params["norc"]?)))

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to uninstall gem: #{result[:stderr]}")
      end

      PluginResult.new(changed: true, failed: false, msg: "Gem removed")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::GemPlugin.new(config)
plugin.run

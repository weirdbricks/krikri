#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Npm plugin - manages Node.js packages via npm. Compatible with (a
  # subset of) community.general.npm.
  #
  # Entirely unimplemented before - robertdebock.node_red's own "Install
  # node-red" task (`community.general.npm: name: node-red, global:
  # yes, unsafe_perm: yes`) silently skipped ("Plugin not available")
  # while real Ansible actually installed the package.
  #
  # Supported parameters (the ones any role benchmarked so far actually
  # uses): name, version, path, global, production, registry,
  # executable, ignore_scripts, unsafe_perm, state (present|absent -
  # `latest`'s own additional `npm outdated`-driven update pass isn't
  # implemented, no role seen so far uses it).
  #
  # Idempotency: mirrors real Ansible's own algorithm exactly - `npm
  # list --json --long [-g]` (from `path` if given), read the
  # `dependencies` hash; a dependency missing an entry, or present with
  # `"missing"`/`"invalid"` set, counts as NOT installed. `state:
  # present` only installs if the target name (optionally `name@version`)
  # isn't already in the installed set; `state: absent` only uninstalls
  # if it IS.
  class NpmPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      state = @params["state"]? || "present"
      # Real Ansible's own arg-spec only requires `name:` when `state:
      # absent` (uninstalling with no target makes no sense) - `state:
      # present`/`latest` with no name installs from the local
      # package.json in `path`/cwd, matching plain `npm install`.
      return PluginResult.new(changed: false, failed: true, msg: "name is required") if state == "absent" && !name

      global = is_true?(@params["global"]?)
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "path is required when global is false") if !global && !path

      version = @params["version"]?
      name_version = version ? "#{name}@#{version}" : name

      if path && !remote_dir_exists?(path)
        remote_exec("mkdir -p #{path}")
      end

      installed, missing = list(name, name_version, global, path)

      case state
      when "absent"
        return PluginResult.new(changed: false, failed: true, msg: "name is required") unless name
        unless installed.includes?(name)
          return PluginResult.new(changed: false, failed: false, msg: "Package already absent")
        end
        result = run_npm(["uninstall"], name_version, global, path)
        return failure(result) unless result[:exit_code] == 0
        PluginResult.new(changed: true, failed: false, msg: "Package removed", stdout: result[:stdout])
      else
        if name_version && missing.empty?
          return PluginResult.new(changed: false, failed: false, msg: "Package already installed")
        end
        result = run_npm(["install"], name_version, global, path)
        return failure(result) unless result[:exit_code] == 0
        PluginResult.new(changed: true, failed: false, msg: "Package installed", stdout: result[:stdout])
      end
    end

    private def failure(result) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "npm command failed: #{result[:stderr]}", stdout: result[:stdout], stderr: result[:stderr])
    end

    private def npm_binary : String
      @params["executable"]? || "npm"
    end

    private def list(name : String?, name_version : String?, global : Bool, path : String?) : {Array(String), Array(String)}
      result = run_npm(["list", "--json", "--long"], nil, global, path, mutating: false)
      installed = [] of String
      missing = [] of String

      begin
        data = JSON.parse(result[:stdout].empty? ? "{}" : result[:stdout])
        if deps = data["dependencies"]?.try(&.as_h?)
          deps.each do |dep, props|
            props_h = props.as_h?
            if props_h && ((props_h["missing"]?.try(&.as_bool?) == true) || (props_h["invalid"]?.try(&.as_bool?) == true))
              missing << dep
            else
              installed << dep
              if props_h && (ver = props_h["version"]?.try(&.as_s?))
                installed << "#{dep}@#{ver}"
              end
            end
          end
        end
      rescue
        # Malformed/empty npm list output - treat as nothing installed,
        # matching this codebase's general "fail closed to a safe no-op
        # read, let the actual install/uninstall command surface any
        # real error" convention used elsewhere (pip.cr, etc).
      end

      if name_version && !installed.includes?(name_version) && name && !missing.includes?(name)
        missing << name
      end

      {installed, missing}
    end

    private def run_npm(subcommand : Array(String), name_version : String?, global : Bool, path : String?, mutating : Bool = true)
      args = subcommand.dup
      args << "--global" if global
      args << "--production" if mutating && is_true?(@params["production"]?)
      args << "--ignore-scripts" if mutating && is_true?(@params["ignore_scripts"]?)
      args << "--unsafe-perm" if mutating && is_true?(@params["unsafe_perm"]?)
      if registry = @params["registry"]?
        args << "--registry" << registry
      end
      args << name_version if name_version

      cmd = "#{npm_binary} #{args.join(' ')}"
      cmd = "cd #{expand_tilde(path)} && #{cmd}" if path
      remote_exec(cmd)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::NpmPlugin.new(config)
plugin.run

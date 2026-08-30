#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
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

      if invalid = validate_npm_args(state, name)
        return invalid
      end

      global = true?(@params["global"]?)
      path = @params["path"]?

      version = @params["version"]?
      name_version = version ? "#{name}@#{version}" : name

      if path && !remote_dir_exists?(path)
        remote_exec("mkdir -p #{path}")
      end

      installed, missing = list(name, name_version, global, path)

      case state
      when "absent"
        handle_absent(name, name_version, global, path, installed)
      else
        handle_present(name_version, global, path, missing)
      end
    end

    # Validate the parameter combinations; returns the failure result or
    # nil when the arguments are valid.
    private def validate_npm_args(state : String, name : String?) : PluginResult?
      # Real Ansible's own arg-spec only requires `name:` when `state:
      # absent` (uninstalling with no target makes no sense) - `state:
      # present`/`latest` with no name installs from the local
      # package.json in `path`/cwd, matching plain `npm install`.
      return PluginResult.new(changed: false, failed: true, msg: "name is required") if state == "absent" && !name

      global = true?(@params["global"]?)
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "path is required when global is false") if !global && !path

      nil
    end

    # state: absent - uninstall the named package when it is installed
    private def handle_absent(name : String?, name_version : String?, global : Bool, path : String?, installed : Array(String)) : PluginResult
      return PluginResult.new(changed: false, failed: true, msg: "name is required") unless name
      unless installed.includes?(name)
        return PluginResult.new(changed: false, failed: false, msg: "Package already absent")
      end
      result = run_npm(["uninstall"], name_version, global, path)
      return failure(result) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: "Package removed", stdout: result[:stdout])
    end

    # state: present (or latest) - install when anything is missing
    private def handle_present(name_version : String?, global : Bool, path : String?, missing : Array(String)) : PluginResult
      # Real Ansible's own `state: present` branch checks `if missing:`
      # alone - it does NOT require a name_version to be given at all.
      # Gating this short-circuit on `name_version &&` (previously)
      # meant a bare `path:`-only install (no `name:`, the common
      # "install everything from package.json" idiom - see round 99's
      # robertdebock.irslackd) always fell through to `npm install`
      # and reported `changed: true` unconditionally, every single
      # run, since `name_version` is nil whenever `name:` is omitted -
      # never actually converging even when every dependency was
      # already correctly installed.
      if missing.empty?
        return PluginResult.new(changed: false, failed: false, msg: "Package already installed")
      end
      result = run_npm(["install"], name_version, global, path)
      return failure(result) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, msg: "Package installed", stdout: result[:stdout])
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

      collect_installed(result[:stdout], installed, missing)

      if name_version && !installed.includes?(name_version) && name && !missing.includes?(name)
        missing << name
      end

      {installed, missing}
    end

    # Parse `npm list --json --long` output into the installed/missing
    # sets. Malformed/empty output - treated as nothing installed,
    # matching this codebase's general "fail closed to a safe no-op
    # read, let the actual install/uninstall command surface any
    # real error" convention used elsewhere (pip.cr, etc).
    private def collect_installed(stdout : String, installed : Array(String), missing : Array(String)) : Nil
      data = JSON.parse(stdout.empty? ? "{}" : stdout)
      if deps = data["dependencies"]?.try(&.as_h?)
        deps.each do |dep, props|
          add_dependency(dep, props.as_h?, installed, missing)
        end
      end
    rescue
    end

    # Classify a single dependency entry from npm list output
    private def add_dependency(dep : String, props_h : Hash(String, JSON::Any)?, installed : Array(String), missing : Array(String)) : Nil
      if props_h && ((props_h["missing"]?.try(&.as_bool?) == true) || (props_h["invalid"]?.try(&.as_bool?) == true))
        missing << dep
      else
        installed << dep
        if props_h && (ver = props_h["version"]?.try(&.as_s?))
          installed << "#{dep}@#{ver}"
        end
      end
    end

    private def run_npm(subcommand : Array(String), name_version : String?, global : Bool, path : String?, mutating : Bool = true)
      args = subcommand.dup
      args << "--global" if global
      append_npm_args(args, mutating, name_version)

      cmd = "#{npm_binary} #{args.join(' ')}"
      cmd = "cd #{expand_tilde(path)} && #{cmd}" if path
      remote_exec(cmd)
    end

    # Append the mutating-mode flags, registry override and package name
    private def append_npm_args(args : Array(String), mutating : Bool, name_version : String?) : Nil
      args << "--production" if mutating && true?(@params["production"]?)
      args << "--ignore-scripts" if mutating && true?(@params["ignore_scripts"]?)
      args << "--unsafe-perm" if mutating && true?(@params["unsafe_perm"]?)
      if registry = @params["registry"]?
        args << "--registry" << registry
      end
      args << name_version if name_version
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::NpmPlugin.new(config)
plugin.run

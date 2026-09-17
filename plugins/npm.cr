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

      # Real Ansible's npm module resolves the executable via
      # `module.get_bin_path(npm_path, True)`, which raises "Failed to
      # find required executable ... in paths: ..." and fails the task
      # outright when npm isn't installed - `list()` below never even
      # gets a chance to be wrong about it. Missing here before: `npm
      # list`'s own shell command just failed silently (bad exit code,
      # empty/garbage stdout), and #collect_installed's "malformed
      # output -> treat as nothing installed" fallback (a deliberate,
      # documented no-op-read-failure convention for THAT case) turned
      # a genuinely missing npm binary into an empty `missing` set,
      # which #handle_present's `missing.empty?` then read as "Package
      # already installed" - a false-positive success reporting nothing
      # was ever actually checked or installed. `which` (not `command
      # -v`, whose own no-op is a SHELL BUILTIN - `remote_exec`'s local-
      # connection path shells out directly, without a shell, for any
      # command string with no metacharacters, so "command -v npm"
      # tried to execve a real file literally named "command", which
      # doesn't exist, and failed regardless of whether npm itself was
      # actually present; `which` is a real external binary, so it
      # works identically whether local_connection? routes through a
      # real shell or execve's it directly) resolves both a bare name
      # and an absolute `executable:` override identically to how the
      # shell itself will later resolve `npm_binary` in #run_npm's own
      # command string.
      global = true?(@params["global"]?)
      path = @params["path"]?

      bin = npm_binary
      if (exe = @params["executable"]?) && exe.includes?("/")
        # Real npm runs an `executable:` PATH VERBATIM (community.general
        # npm: `kwargs["executable"].split(" ")` bypasses get_bin_path;
        # CmdRunner only re-resolves a bare name) - so a missing path
        # surfaces as the raw OSError from run_command, failed with
        # rc=errno and the command string (podman-diff npm_edge_cases
        # N7), NOT the get_bin_path wording. The `which` pre-check
        # below stays for the bare-name/default case only.
        check = remote_exec("test -e #{exe}")
        if check[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "[Errno 2] No such file or directory: b'#{exe}'",
            rc: 2, cmd: "#{exe} list --json --long#{global ? " --global" : ""}")
        end
      else
        check = remote_exec("which #{bin}")
        if check[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to find required executable \"#{bin}\" in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        end
      end

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
      # Real Ansible's own arg-spec requires `name:` when `state:
      # absent` (uninstalling with no target makes no sense) - `state:
      # present`/`latest` with no name installs from the local
      # package.json in `path`/cwd, matching plain `npm install`.
      # Both messages are real's own required_if wording (community.general
      # npm argument_spec: `required_if=[("state", "absent", ["name"]),
      # ("global", False, ["path"])]` - "<option> is <value> but all of
      # the following are missing: <missing>").
      return PluginResult.new(changed: false, failed: true, msg: "state is absent but all of the following are missing: name") if state == "absent" && !name

      global = true?(@params["global"]?)
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "global is False but all of the following are missing: path") if !global && !path

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

    private def run_npm(subcommand : Array(String), name_version : String?, global : Bool, path : String?, mutating : Bool = true) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
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

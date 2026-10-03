#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/get_bin_path"
require "../src/krikri/plugin_helpers/run_command_failure"

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
    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /usr/local/sbin]
    @searched_paths = ""
    @npm_path = "npm"

    # get_bin_path on the target: $PATH plus the sbin dirs real appends
    # when missing from PATH. Returns the first executable hit (absolute),
    # else nil; leaves the searched list in @searched_paths.
    private def find_binary(name : String) : String?
      script = <<-SH
        found=""
        searched=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          case ":$searched:" in *":$d:"*) ;; *) searched="${searched:+$searched:}$d" ;; esac
          if [ -z "$found" ] && [ -x "$d/#{name}" ]; then found="$d/#{name}"; fi
        done
        printf '%s\n%s' "$found" "$searched"
        SH

      result = remote_exec(script)
      found, _, searched = result[:stdout].to_s.partition("\n")
      found = found.strip
      searched = searched.strip
      @searched_paths = searched
      found.empty? ? nil : found
    end

    def execute : PluginResult
      name = @params["name"]?
      state = @params["state"]? || "present"

      if invalid = validate_npm_args(state, name)
        return invalid
      end

      # Real Ansible's npm module resolves the executable via
      # `module.get_bin_path("npm", True)` inside the Npm() constructor -
      # AFTER the required_if checks (validate_npm_args above), BEFORE any
      # command runs - failing "Failed to find required executable ... in
      # paths: ..." when npm isn't installed. An `executable:` override
      # runs through `kwargs["executable"].split(" ")` - but only VERBATIM
      # when it is a path: CmdRunner RE-RESOLVES a bare name through
      # get_bin_path (live-verified vs 2.19.11: a bare nonexistent name
      # fails with the get_bin_path wording, not the OSError shape). A
      # missing/unexecutable PATH override surfaces the raw run_command
      # OSError shape from the FIRST command (the list probe), with
      # rc=errno and the space-joined command string (podman-diff
      # npm_edge_cases N7).
      global = true?(@params["global"]?)
      path = @params["path"]?

      if exe = @params["executable"]?
        exe_parts = exe.split(' ').reject(&.empty?)
        unless exe_parts[0].includes?("/")
          found = find_binary(exe_parts[0])
          return PluginResult.new(changed: false, failed: true,
            msg: PluginHelpers::GetBinPath.missing_executable_error(exe_parts[0], @searched_paths)) unless found
          @npm_path = found
          exe_parts = [found]
        end
      else
        found = find_binary("npm")
        return PluginResult.new(changed: false, failed: true,
          msg: PluginHelpers::GetBinPath.missing_executable_error("npm", @searched_paths)) unless found
        @npm_path = found
        exe_parts = [found]
      end

      version = @params["version"]?
      name_version = version ? "#{name}@#{version}" : name

      # Real _exec: a given `path` is created when missing (os.makedirs)
      # and fails with "path {path} is not a directory" when it exists as
      # something else; it is passed to run_command as cwd.
      if path && !remote_dir_exists?(path)
        remote_exec("mkdir -p #{Process.quote(path)}")
      end
      if path && remote_file_exists?(path) && !remote_dir_exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "path #{path} is not a directory")
      end

      # The first command real runs is the exec's failure surface: with
      # ci=true real runs `npm ci` DIRECTLY (main()'s ci branch never
      # lists), for every other state it's the list probe (check_rc=False,
      # so only an exec-start failure kills the task here) - a missing or
      # unexecutable `executable:` path surfaces run_command's OSError
      # shape with rc=errno and the space-joined FIRST command string.
      ci = true?(@params["ci"]?)
      first_args = ci ? build_args(["ci"], name_version, global, mutating: true) : build_args(["list", "--json", "--long"], nil, global, mutating: false)
      if failure = PluginHelpers::RunCommandFailure.exec_check(exe_parts[0])
        return PluginHelpers::RunCommandFailure.exec_failure(exe_parts[0], failure[0], failure[1], (exe_parts + first_args).join(' '))
      end

      if ci
        # Real main(): the ci branch runs `npm ci` unconditionally and
        # exits changed=true (no list, no installed-set check).
        result = run_npm(exe_parts, ["ci"], name_version, global, path)
        return failure(exe_parts, result, ["ci"]) unless result[:exit_code] == 0
        return PluginResult.new(changed: true, failed: false)
      end

      installed, missing = list(exe_parts, name, name_version, global, path)

      case state
      when "absent"
        handle_absent(exe_parts, name, name_version, global, path, installed)
      else
        handle_present(exe_parts, name_version, global, path, missing)
      end
    end

    # Validate the parameter combinations; returns the failure result or
    # nil when the arguments are valid.
    private def validate_npm_args(state : String, name : String?) : PluginResult?
      # Real Ansible's own arg-spec requires `name:` when `state:
      # absent` (uninstalling with no target makes no sense) - the sweep
      # environment's community.general (11.2.1, Debian trixie's ansible
      # package) keeps that as required_if wording, and its `path` check
      # is a module-level explicit one (NOT required_if): "path must be
      # specified when not using global", fired right after arg-spec
      # validation, BEFORE the npm binary is even looked up (live-verified
      # vs the sweep container's module source, general 11.2.1).
      return PluginResult.new(changed: false, failed: true, msg: "state is absent but all of the following are missing: name") if state == "absent" && !name

      global = true?(@params["global"]?)
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "path must be specified when not using global") if !global && !path

      nil
    end

    # state: absent - uninstall the named package when it is installed
    private def handle_absent(exe_parts : Array(String), name : String?, name_version : String?, global : Bool, path : String?, installed : Array(String)) : PluginResult
      return PluginResult.new(changed: false, failed: true, msg: "name is required") unless name
      unless installed.includes?(name)
        return PluginResult.new(changed: false, failed: false, key_order: %w[changed])
      end
      result = run_npm(exe_parts, ["uninstall"], name_version, global, path)
      return failure(exe_parts, result, ["uninstall"]) unless result[:exit_code] == 0
      # Real 2.19.11 (live-verified + module source): npm.py has ONE
      # exit - exit_json(changed=changed) - so success results carry no
      # msg/stdout at all (the "Package removed"/"already absent" msgs
      # were this plugin's own borrow).
      PluginResult.new(changed: true, failed: false, key_order: %w[changed])
    end

    # state: present (or latest) - install when anything is missing
    private def handle_present(exe_parts : Array(String), name_version : String?, global : Bool, path : String?, missing : Array(String)) : PluginResult
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
        return PluginResult.new(changed: false, failed: false, key_order: %w[changed])
      end
      result = run_npm(exe_parts, ["install"], name_version, global, path)
      return failure(exe_parts, result, ["install"]) unless result[:exit_code] == 0
      PluginResult.new(changed: true, failed: false, key_order: %w[changed])
    end

    # Real _exec with check_rc=True: a started-but-failed command fails
    # with msg=stderr.rstrip() plus cmd/rc/stdout/stderr.
    private def failure(exe_parts : Array(String), result, args : Array(String)) : PluginResult
      PluginHelpers::RunCommandFailure.nonzero_exit(
        (exe_parts + args).join(' '), result[:exit_code], result[:stdout], result[:stderr]
      )
    end

    private def npm_binary : String
      @params["executable"]? || @npm_path
    end

    private def list(exe_parts : Array(String), name : String?, name_version : String?, global : Bool, path : String?) : {Array(String), Array(String)}
      result = run_npm(exe_parts, ["list", "--json", "--long"], nil, global, path, mutating: false)
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

    # Real CmdRunner arg order (community.general npm.py's
    # "exec_args global_ production ignore_scripts unsafe_perm
    # name_version registry no_optional no_bin_links force"), with
    # production gated to install/update/ci commands. Exec failure
    # (missing/unexecutable binary) surfaces before anything runs as
    # run_command's OSError shape with the SPACE-JOINED raw args as cmd
    # (real's _clean_args - no shell quoting).
    private def run_npm(exe_parts : Array(String), subcommand : Array(String), name_version : String?, global : Bool, path : String?, mutating : Bool = true) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      args = build_args(subcommand, name_version, global, mutating)

      cmd = "#{Process.quote(npm_binary)} #{args.map { |arg| Process.quote(arg) }.join(' ')}"
      cmd = "cd #{Process.quote(expand_tilde(path))} && #{cmd}" if path
      remote_exec(cmd)
    end

    # The flag sequence real's CmdRunner composes, in its own order
    # ("exec_args global_ production ignore_scripts unsafe_perm
    # name_version registry no_optional no_bin_links force"), with
    # production gated to install/update/ci commands.
    private def build_args(subcommand : Array(String), name_version : String?, global : Bool, mutating : Bool) : Array(String)
      args = subcommand.dup
      args << "--global" if global
      if mutating
        args << "--production" if true?(@params["production"]?) && subcommand.any? { |arg| ["install", "update", "ci"].includes?(arg) }
        args << "--ignore-scripts" if true?(@params["ignore_scripts"]?)
        args << "--unsafe-perm" if true?(@params["unsafe_perm"]?)
        args << name_version if name_version
        if registry = @params["registry"]?
          args << "--registry" << registry
        end
        args << "--no-optional" if true?(@params["no_optional"]?)
        args << "--no-bin-links" if true?(@params["no_bin_links"]?)
        args << "--force" if true?(@params["force"]?)
      else
        # The list probe still carries the truthy-only flags and the
        # registry override (real passes the full param set through
        # CmdRunner for list too) - but never the package name.
        args << "--ignore-scripts" if true?(@params["ignore_scripts"]?)
        args << "--unsafe-perm" if true?(@params["unsafe_perm"]?)
        if registry = @params["registry"]?
          args << "--registry" << registry
        end
        args << "--no-optional" if true?(@params["no_optional"]?)
        args << "--no-bin-links" if true?(@params["no_bin_links"]?)
        args << "--force" if true?(@params["force"]?)
      end
      args
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::NpmPlugin.new(config)
plugin.run

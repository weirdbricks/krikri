#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/get_bin_path"
require "../src/krikri/plugin_helpers/gem_command"
require "../src/krikri/plugin_helpers/run_command_failure"

module Krikri
  # Gem plugin - manages Ruby gems via the `gem` CLI. Compatible with (a
  # subset of) Ansible's community.general.gem module - Ansible's
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
  #   `--user-install` (default true, matching Ansible's own
  #   default) rather than system-wide
  # - bindir: custom `--bindir` for installed executables
  #
  # Idempotency: `present` (no version:) checks parsed `gem list` output
  # for existence at ANY version - already installed is a no-op,
  # matching Ansible's own default behavior. `present` with a
  # version: does Ansible's exact-string membership test against
  # the parsed version list (NOT `gem list -i -v`) - so a version
  # SPECIFIER (">= 1.0") is deliberately non-idempotent here exactly as
  # it is in Ansible, where the specifier never matches a parsed
  # version string. `latest` resolves the latest remote version first
  # (Ansible's own remote listing) and then runs the same
  # exact-version check - so an already-latest gem is a no-op with
  # changed=false, and `version` together with `latest` fails with
  # Ansible's own validation message. `gem install` on an already-latest
  # gem is a real no-op at the `gem` CLI level, but this module doesn't
  # attempt to distinguish that from a real upgrade in its own changed:
  # reporting - narrower than pip.cr's own state: latest handling,
  # revisit if a real playbook needs it).
  #
  # - repository: `--source <repository>`
  # - include_dependencies: default true (matching Ansible's own
  #   default exactly - NOT false) - only ever adds a flag
  #   (`--ignore-dependencies`) when explicitly set false; true adds
  #   nothing (modern rubygems installs dependencies by default with no
  #   flag needed)
  # - norc: `--norc` - Ansible gates this on the installed rubygems
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
      executable = @params["executable"]?
      version = @params["version"]?
      gem_source = @params["gem_source"]?
      repository = @params["repository"]?

      # AnsibleModule argument_spec: mutually_exclusive=[("gem_source",
      # "repository"), ("gem_source", "version")] - validated at module
      # setup, before main()'s own checks.
      if gem_source && repository
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: gem_source|repository")
      end
      if gem_source && version
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: gem_source|version")
      end

      # Real main()'s own pre-checks run in this exact order, BEFORE any
      # command runs - including the `<gem> --version` probe (the sweep
      # environment's community.general 11.2.1 gem.py: version+latest,
      # then gem_source+latest, then user_install+install_dir - all three
      # fire even when the gem binary is missing or unexecutable).
      if version && state == "latest"
        return PluginResult.new(changed: false, failed: true, msg: "Cannot specify version when state=latest")
      end
      if gem_source && state == "latest"
        return PluginResult.new(changed: false, failed: true, msg: "Cannot maintain state=latest when installing from local source")
      end
      user_install = @params["user_install"]?.nil? || true?(@params["user_install"]?)
      install_dir = @params["install_dir"]?
      if user_install && install_dir
        return PluginResult.new(changed: false, failed: true, msg: "install_dir requires user_install=false")
      end

      # Ansible's gem module's first COMMAND is always `<gem> --version`
      # (get_rubygems_version via common_opts, run with check_rc=True) -
      # a missing/unexecutable binary fails here, after the pre-checks
      # above, before the state dispatch below.
      if probe_error = rubygems_probe(executable)
        return probe_error
      end

      case state
      when "absent"
        remove(executable, name, version)
      when "latest"
        # Ansible resolves the latest REMOTE version first and then
        # runs the same exact-version installed check as state=present,
        # so state=latest is idempotent for an already-latest gem (the
        # remote listing costs a network round-trip, and an unreachable
        # registry degrades to the "any version installed" check - both
        # real behaviors, kept). Verified against Ansible's gem module's exists():
        # the version param is an exact-string membership test against
        # parsed `gem list` output - NOT `gem list -i -v` - which is why
        # version specifiers (">= 1.0") are deliberately non-idempotent
        # in Ansible: the specifier never matches a parsed version
        # string, so the module reinstalls on every run. Matching that
        # exactly, including the non-idempotence.
        resolved = list_versions(executable, name, remote: true)[0]?
        install(executable, name, resolved, force: false)
      else
        install(executable, name, version, force: false)
      end
    end

    # Ansible's gem module's first command is always `<gem> --version`
    # (get_rubygems_version via common_opts, run with check_rc=True) - so
    # a missing/unexecutable binary fails before anything else:
    #  - an `executable:` override is used VERBATIM (Ansible's
    #    executable.split(" "), no PATH search): a path that cannot be
    #    exec'd surfaces run_command's OSError shape
    #  - without one, get_bin_path('gem', True) fails with its own
    #    "Failed to find required executable ..." ValueError-turned-msg
    # Also returns the RESOLVED binary path (absolute when the search
    # found one) for the subsequent command builders.
    private def rubygems_probe(executable : String?) : (PluginResult | Nil)
      if exe = executable
        # Real splits the override on spaces ("/path/to/gem --flag" style
        # executables); every part goes into the command verbatim.
        parts = exe.split(' ').reject(&.empty?)
        cmd = (parts + ["--version"]).join(' ')
        @gem_path = parts[0]
        if failure = PluginHelpers::RunCommandFailure.exec_check(parts[0])
          return PluginHelpers::RunCommandFailure.exec_failure(parts[0], failure[0], failure[1], cmd)
        end
        result = remote_exec(cmd)
        return PluginHelpers::RunCommandFailure.nonzero_exit(cmd, result[:exit_code], result[:stdout], result[:stderr]) unless result[:exit_code] == 0
        nil
      else
        found = find_binary("gem")
        return PluginResult.new(changed: false, failed: true,
          msg: PluginHelpers::GetBinPath.missing_executable_error("gem", @searched_paths)) unless found
        @gem_path = found
        result = remote_exec("#{found} --version")
        return PluginHelpers::RunCommandFailure.nonzero_exit("#{found} --version", result[:exit_code], result[:stdout], result[:stderr]) unless result[:exit_code] == 0
        nil
      end
    end

    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /usr/local/sbin]
    @searched_paths = ""
    @gem_path = "gem"

    # get_bin_path on the target: opt_dirs (none here) + $PATH + the sbin
    # dirs real appends when missing from PATH. Returns the first
    # executable hit (absolute), else nil, and leaves the searched list
    # in @searched_paths for the failure message.
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

    # Ansible's get_installed_versions: `gem list --norc "^name$"`
    # (optionally --remote), each line parsed with
    # /\S+\s+\((?:default: )?(.+)\)/, versions split on ", ", platform
    # suffixes (everything after the first token) stripped - and then an
    # exact-string membership test for the version param.
    private def list_versions(executable : String?, name : String, remote : Bool) : Array(String)
      cmd = %Q(#{gem_binary(executable)} list --norc #{remote ? "--remote " : ""}"^#{name}$")
      result = remote_exec(cmd)
      PluginHelpers::GemCommand.parse_list_versions(result[:stdout])
    end

    private def installed?(executable : String?, name : String, version : String?) : Bool
      versions = list_versions(executable, name, remote: false)
      version ? versions.includes?(version) : !versions.empty?
    end

    private def install(executable : String?, name : String, version : String?, force : Bool) : PluginResult
      unless force
        return gem_success(false, name, version) if installed?(executable, name, version)
      end

      user_install = @params["user_install"]?.nil? || true?(@params["user_install"]?)
      bindir = @params["bindir"]?
      include_dependencies = @params["include_dependencies"]?.nil? || true?(@params["include_dependencies"]?)

      cmd = PluginHelpers::GemCommand.install_command(
        gem_binary(executable), name, version, user_install, bindir,
        @params["repository"]?, include_dependencies, true?(@params["norc"]?)
      )

      result = remote_exec(cmd)
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to install gem: #{result[:stderr]}", stdout: result[:stdout], stderr: result[:stderr])
      end

      gem_success(true, name, version)
    end

    private def remove(executable : String?, name : String, version : String?) : PluginResult
      return gem_success(false, name, version) unless installed?(executable, name, version)

      result = remote_exec(PluginHelpers::GemCommand.uninstall_command(gem_binary(executable), name, version, true?(@params["norc"]?)))

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to uninstall gem: #{result[:stderr]}")
      end

      gem_success(true, name, version)
    end

    # Real community.general gem.py builds every success result as
    # result["name"], result["state"], result["version"] (only when a
    # version was requested) then result["changed"], and exits with
    # exit_json(**result) - no msg, no stdout (the "Gem installed"/
    # "already installed" texts and the raw gem output were krikri's own
    # borrows; dropped, npm-style). Live-verified in a Fedora 41
    # container for the changed install, the unchanged rerun and check
    # mode (all register exactly {name, state, changed, failed}); the
    # version-echo position is from module source (result["version"]
    # only when truthy).
    private def gem_success(changed : Bool, name : String, version : String?) : PluginResult
      state = @params["state"]? || "present"
      if version
        PluginResult.new(changed: changed, failed: false, name: name, state: state, version: version,
          key_order: %w[name state version changed])
      else
        PluginResult.new(changed: changed, failed: false, name: name, state: state,
          key_order: %w[name state changed])
      end
    end

    # The binary name for command building: a resolved absolute path when
    # no executable: override was given (Ansible's get_bin_path result).
    private def gem_binary(executable : String?) : String
      executable || @gem_path
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::GemPlugin.new(config)
plugin.run

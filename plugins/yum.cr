#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/rpm_package"

module Krikri
  # Yum plugin - manages packages with the `yum` command. Compatible with
  # Ansible's ansible.builtin.yum module - a near-duplicate of dnf.cr's
  # own DnfPlugin (see build.sh's own convention of one tiny compiled
  # binary per module rather than shared library code between them),
  # shelling `yum` instead of `dnf` throughout.
  #
  # Verified live against a Rocky 9.6 target, where `/usr/bin/yum` is
  # itself a symlink to `dnf-3` (the standard modern RHEL-family setup
  # since RHEL8/CentOS8) - the flags this builds (`--setopt=install_
  # weak_deps=False`, `--best`, `--allowerasing`) are real dnf options
  # forwarded straight through that symlink. NOT verified against a
  # genuinely dnf-less yum (RHEL6/7-era) target - those flags don't
  # exist on classic yum, and real ansible.builtin.yum's own module
  # internally detects and branches on which backend it's talking to,
  # which this does not replicate. No RHEL7-or-older Atlantic.net image
  # was available to verify that path this round.
  #

  # Supports key Ansible dnf module parameters:
  # - name: Package name(s), group (@group), URL, or local RPM file
  # - state: present, installed, absent, removed, latest
  # - enablerepo: Repository to enable for this operation
  # - disablerepo: Repository to disable for this operation
  # - disable_gpg_check: Disable GPG signature checking
  # - update_only: Only update packages, don't install new ones
  # - autoremove: Remove unneeded dependencies
  # - security: Only install security updates (with state=latest)
  # - bugfix: Only install bugfix updates (with state=latest)
  # - install_weak_deps: Install weak dependencies (default: true)
  # - skip_broken: Skip packages with broken dependencies
  # - allow_downgrade: Allow downgrading packages
  #
  # Examples:
  #   dnf:
  #     name: httpd
  #     state: present
  #
  #   dnf:
  #     name:
  #       - httpd
  #       - nginx
  #     state: latest
  #
  #   dnf:
  #     name: "@Development tools"
  #     state: present
  class YumPlugin < BasePlugin
    include PluginHelpers::RpmPackage

    private def pkg_manager_binary : String
      "yum"
    end

    # Real ansible.builtin.yum's argument-spec validation rejects ANY
    # parameter outside its argument_spec at module-arg validation,
    # before any module code runs - same bug class as dnf.cr's
    # identical check (found via the podman-diff dnf_edge_cases N2
    # harness case, and yum shares dnf's yumdnf_argument_spec minus
    # dnf-only allowerasing, plus use_backend which yum.py uses for
    # its own backend detection). On a non-RPM host real yum fails
    # even earlier - "Could not detect which major revision of yum
    # is in use ..." (live-verified on Debian) - so this message
    # shape is unverifiable on the Debian podman-diff harness and
    # mirrors dnf's live-verified one. check_mode/diff_mode/
    # _verbosity/_environment are engine-internal keys injected by
    # the executor, not part of the real argument_spec, so they are
    # not rejected.
    private def arg_spec_rejection : PluginResult?
      yum_supported = {"allow_downgrade", "autoremove", "bugfix", "cacheonly",
                       "conf_file", "disable_excludes", "disable_gpg_check",
                       "disable_plugin", "disablerepo", "download_dir", "download_only",
                       "enable_plugin", "enablerepo", "exclude", "install_repoquery",
                       "install_weak_deps", "installroot", "list", "lock_timeout",
                       "name", "nobest", "releasever", "security", "skip_broken",
                       "sslverify", "state", "update_cache", "update_only",
                       "validate_certs", "use_backend", "expire-cache", "pkg"}
      yum_internal = {"check_mode", "diff_mode", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| yum_supported.includes?(k) || yum_internal.includes?(k) }
      unless unsupported.empty?
        unsupported_sorted = unsupported.sort
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.builtin.yum) module: #{unsupported_sorted.join(", ")}. " \
               "Supported parameters include: " \
               "allow_downgrade, autoremove, bugfix, cacheonly, conf_file, disable_excludes, disable_gpg_check, " \
               "disable_plugin, disablerepo, download_dir, download_only, enable_plugin, enablerepo, exclude, " \
               "install_repoquery, install_weak_deps, installroot, list, lock_timeout, name, nobest, releasever, " \
               "security, skip_broken, sslverify, state, update_cache, update_only, validate_certs, " \
               "use_backend (expire-cache, pkg)."
        )
      end

      # Real AnsibleModule type-converts every bool-typed argument_spec
      # param and fails the task on a non-boolean string - same bug
      # class as dnf.cr's identical check (disable_gpg_check: sometimes
      # live-verified against bookworm's ansible-core 2.14 dnf). Params
      # arrive as strings here; lowercase compare matches
      # AnsibleModule's own case-insensitive boolean() check.
      yum_bool_params = {"allow_downgrade", "autoremove", "bugfix", "cacheonly",
                         "disable_gpg_check", "download_only", "install_repoquery",
                         "install_weak_deps", "nobest", "security", "skip_broken",
                         "sslverify", "update_cache", "update_only", "validate_certs",
                         "expire-cache"}
      valid_booleans = {"0", "1", "true", "off", "yes", "t", "false", "on", "f", "n", "y", "no"}
      bad_bool_keys = @params.select { |k, v| yum_bool_params.includes?(k) && !valid_booleans.includes?(v.downcase) }.keys
      bad_bool = bad_bool_keys.sort
      unless bad_bool.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "argument '#{bad_bool.first}' is of type <class 'str'> and we were unable to convert to bool: " \
               "The value '#{@params[bad_bool.first]}' is not a valid boolean.  " \
               "Valid booleans include: 0, 1, 'true', 'off', 'yes', '1', 't', '0', 'false', 'on', 'f', 'n', 'y', 'no'"
        )
      end

      nil
    end

    def execute : PluginResult
      if failure = arg_spec_rejection
        return failure
      end

      if list_result = list_query_result
        return list_result
      end

      # Parse package name(s)
      # Can be a string, array (via list parameter), or comma-separated
      names = parse_package_names

      # `name:` isn't required when `update_cache: true` is given with
      # nothing else - real Ansible's own yum: module allows a cache-
      # refresh-only invocation (robertdebock.rpmfusion's own "Yum
      # update cache" handler: `ansible.builtin.yum: {update_cache:
      # yes}`, no name: at all). Matches package.cr's own identical
      # exception for the generic package: module - never ported here
      # until this task's own "Missing required parameter: name"
      # failure surfaced it live on a Rocky 9.6 target.
      if early = early_result_for_empty_names(names)
        return early
      end

      # Get state (default: present) and normalize state aliases
      state = normalized_state

      # Validate state (message matches real Ansible's choices-validation
      # wording - same class as dnf.cr's aligned message)
      unless ["present", "absent", "latest"].includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "value of state must be one of: absent, installed, latest, present, removed, got: #{@params["state"]? || state}"
        )
      end

      # Handle special cases: autoremove or upgrade-all without package name
      if special = special_case_result(names, state)
        return special
      end

      # Build DNF command options
      dnf_options = build_dnf_options

      # Process based on state
      case state
      when "present"
        handle_install(names, dnf_options)
      when "absent"
        handle_remove(names, dnf_options)
      when "latest"
        handle_update(names, dnf_options)
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unexpected state: #{state}"
        )
      end
    end

    # Result to return early when no package names were given: either a
    # cache-only refresh (with `update_cache: true`), or the missing-name
    # failure. Returns nil when names is non-empty.

    # Get state (default: present) with aliases normalized

    # Handle special case: autoremove or upgrade-all with no package names

    # Parse package names from various parameter formats

    # Parse the 'name' parameter (can be string or list) - `pkg:` is a
    # documented alias of `name:` for real Ansible's yum module, same
    # as dnf.cr's own identical fix. Returns nil when neither parameter
    # is present.

    # `name: "{{ some_list_var }}"` templates a *list* var through a
    # plain `{{ }}` substitution - since @params values are always
    # String, that renders as the var's JSON form (`["foo","bar"]`),
    # not a bare comma-joined string. Parsed as real JSON here rather
    # than falling into the comma-split below, which would otherwise
    # leave the brackets/quotes stuck to the first/last entries (see
    # apt.cr's own parse_package_names for the same bug, found via
    # konstruktoid-hardening's package installation task). Returns nil
    # when the trimmed value isn't a bracketed list or fails to parse.

    # See dnf.cr's identical helper for the full rationale - this plugin
    # shells out to the same underlying `dnf` binary on modern RHEL-family
    # hosts (yum is a dnf shim there), so it hits the same "Error: Unknown
    # repo: 'X'" hard-failure for an `enablerepo:` naming a repo that isn't
    # configured, where real ansible.builtin.yum's own dnf-API-based
    # implementation just warns and continues.

    # Build DNF command line options

    # Install packages

    # Classify each requested package into install/update/already-installed
    # buckets based on its current state and the update_only mode.

    # Outcome of a batch install/update command: whether it changed
    # anything, an optional message, captured stdout, and a non-nil
    # failure result when the command itself failed.
    private alias BatchOutcome = NamedTuple(changed: Bool, message: String?, output: String, failure: PluginResult?)

    # Run `yum install` for the given packages and interpret its result

    # Run `yum update` for the given packages and interpret its result

    # Remove packages

    # Update packages to latest version

    # Upgrade all packages

    # Handle autoremove operation

    # Check if a package is installed

    # Check if name is a package group (starts with @)

    # Check if name is a URL or file path

    # Quote package name if it contains special characters
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::YumPlugin.new(config)
plugin.run

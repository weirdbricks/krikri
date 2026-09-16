#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/rpm_package"

module Krikri
  # DNF plugin - manages packages with the dnf package manager
  # Compatible with Ansible's ansible.builtin.dnf module
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
  # - allowerasing: Allow erasing installed packages to resolve deps
  # - nobest: Highest-version-or-fail handling (real Ansible has only
  #   `nobest` in its shared yumdnf argument spec - `best:` is NOT a
  #   real parameter and is rejected by the argument-spec check below)
  # - cacheonly: Run entirely from the local cache
  # - conf_file: Alternate dnf.conf path
  # - disable_excludes: all / main / <repoid> excludes suppression
  # - enable_plugin / disable_plugin: Per-transaction plugin toggles
  # - exclude: Package name(s) to exclude from present/latest
  # - installroot: Alternate install root
  # - releasever: Different OS release version
  # - sslverify: Repo-server SSL validation (default true)
  # - download_only / download_dir: Download without installing
  # - install_repoquery: Accepted as a no-op, matching real Ansible's
  #   own documented behavior for DNF (deprecated, removed in 2.20)
  # - lock_timeout: Accepted as a no-op for the dnf backend, matching
  #   real Ansible's own dnf.py (the dnf python API handles lock
  #   waiting internally; only the retired yum backend consumed it)
  # - use_backend: Which backend module real Ansible would dispatch to
  #   (auto/dnf/yum/yum4/dnf4/dnf5); validated against real Ansible's
  #   choice list, then treated as a no-op since krikri has a single
  #   dnf implementation to select between
  # - validate_certs: Accepted as a no-op; real Ansible only applies it
  #   controller-side when fetching an https RPM URL before install,
  #   which krikri doesn't do (URL rpms are installed on-target by dnf
  #   itself, governed by sslverify instead)
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
  class DnfPlugin < BasePlugin
    include PluginHelpers::RpmPackage

    private def pkg_manager_binary : String
      "dnf"
    end

    # Real ansible.builtin.dnf's argument-spec validation rejects ANY
    # parameter outside its argument_spec at module-arg validation,
    # before any module code runs - found via the podman-diff
    # dnf_edge_cases N2 harness case (real ansible-core rejected
    # krikri_not_a_dnf_param with the message below while this engine
    # silently ignored the unknown key and proceeded to the backend
    # failure). Message live-verified against bookworm's
    # ansible-core 2.14. check_mode/diff_mode/_verbosity/_environment
    # are engine-internal keys injected by the executor, not part of
    # the real argument_spec, so they are not rejected. (use_backend
    # is in upstream's dnf argument_spec per dnf.py, so it stays
    # accepted here; bookworm's 2.14 rejects it live - a known
    # version difference, left matching upstream's spec.)
    private def arg_spec_rejection : PluginResult?
      dnf_supported = {"allow_downgrade", "allowerasing", "autoremove", "bugfix",
                       "cacheonly", "conf_file", "disable_excludes", "disable_gpg_check",
                       "disable_plugin", "disablerepo", "download_dir", "download_only",
                       "enable_plugin", "enablerepo", "exclude", "install_repoquery",
                       "install_weak_deps", "installroot", "list", "lock_timeout",
                       "name", "nobest", "releasever", "security", "skip_broken",
                       "sslverify", "state", "update_cache", "update_only",
                       "validate_certs", "use_backend", "expire-cache", "pkg"}
      dnf_internal = {"_ansible_check_mode", "_ansible_diff", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| dnf_supported.includes?(k) || dnf_internal.includes?(k) }
      unless unsupported.empty?
        unsupported_sorted = unsupported.sort
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.builtin.dnf) module: #{unsupported_sorted.join(", ")}. " \
               "Supported parameters include: " \
               "allow_downgrade, allowerasing, autoremove, bugfix, cacheonly, conf_file, disable_excludes, " \
               "disable_gpg_check, disable_plugin, disablerepo, download_dir, download_only, enable_plugin, " \
               "enablerepo, exclude, install_repoquery, install_weak_deps, installroot, list, lock_timeout, " \
               "name, nobest, releasever, security, skip_broken, sslverify, state, update_cache, update_only, " \
               "validate_certs (expire-cache, pkg)."
        )
      end

      # Real AnsibleModule type-converts every bool-typed argument_spec
      # param and fails the task on a non-boolean string with exactly
      # this message (live-verified: disable_gpg_check: sometimes on
      # bookworm's ansible-core 2.14). Without it this engine accepted
      # e.g. `disable_gpg_check: sometimes` as a truthy value and ran
      # the transaction anyway. Params arrive as strings here (YAML
      # booleans were stringified by the parser); lowercase compare
      # matches AnsibleModule's own case-insensitive boolean() check.
      dnf_bool_params = {"allow_downgrade", "allowerasing", "autoremove", "bugfix",
                         "cacheonly", "disable_gpg_check", "download_only",
                         "install_repoquery", "install_weak_deps", "nobest",
                         "security", "skip_broken", "sslverify", "update_cache",
                         "update_only", "validate_certs", "expire-cache"}
      valid_booleans = {"0", "1", "true", "off", "yes", "t", "false", "on", "f", "n", "y", "no"}
      bad_bool_keys = @params.select { |k, v| dnf_bool_params.includes?(k) && !valid_booleans.includes?(v.downcase) }.keys
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

      # use_backend: real Ansible's argument spec (dnf.py:
      # choices=['auto', 'dnf', 'yum', 'yum4', 'dnf4', 'dnf5']) rejects
      # anything else with the standard choices-validation message
      # before any module code runs. 'yum'/'yum4'/'dnf4' are accepted
      # aliases ('yum'/'yum4' for compatibility - the actual yum backend
      # was removed in ansible-core 2.17), and all choices route to this
      # plugin's single dnf implementation: krikri has no dnf4/dnf5
      # backend split to select between, so a valid choice is a no-op
      # here by design.
      if use_backend = @params["use_backend"]?
        valid_backends = ["auto", "dnf", "yum", "yum4", "dnf4", "dnf5"]
        unless valid_backends.includes?(use_backend)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "value of use_backend must be one of: #{valid_backends.join(", ")}, got: #{use_backend}"
          )
        end
      end

      if list_result = list_query_result
        return list_result
      end

      names = parse_package_names

      if early = early_result_for_empty_names(names)
        return early
      end

      state = normalized_state

      unless ["present", "absent", "latest"].includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "value of state must be one of: absent, installed, latest, present, removed, got: #{@params["state"]? || state}"
        )
      end

      if special = special_case_result(names, state)
        return special
      end

      dnf_options = build_dnf_options

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

    # Parse package names from various parameter formats

    # Real ansible.builtin.dnf's module code goes through dnf's Python API
    # directly, which treats an `enablerepo:` naming a repo ID that isn't
    # configured on the host (e.g. `enablerepo: epel` with no epel-release
    # installed - buluma.elasticsearch_curator's own setup-RedHat.yml does
    # exactly this) as a warning, not a fatal error, and proceeds with
    # whatever repos ARE available. The raw `dnf` CLI this plugin shells
    # out to is stricter and hard-fails with "Error: Unknown repo: 'X'"
    # instead - found benchmarking round166's buluma.elasticsearch_curator
    # on Rocky 9.6 (krikri-playbook failed the task, real ansible-playbook
    # installed successfully via whatever repos were already present).
    # Strip the offending --enablerepo=X flag(s) and retry rather than
    # failing the task, matching real Ansible's lenient behavior.

    # Build DNF command line options

    # Install packages

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

plugin = Krikri::DnfPlugin.new(config)
plugin.run

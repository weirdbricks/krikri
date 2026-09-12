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
  # - best / nobest: Highest-version-or-fail handling (mutually
  #   exclusive; nobest is the inverted form kept for compatibility)
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

    def execute : PluginResult
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
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
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

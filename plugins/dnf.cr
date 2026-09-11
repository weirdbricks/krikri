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

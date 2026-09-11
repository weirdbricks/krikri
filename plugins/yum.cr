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

    def execute : PluginResult
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

      # Validate state
      unless ["present", "absent", "latest"].includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
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

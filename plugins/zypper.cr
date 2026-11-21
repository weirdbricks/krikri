#!/usr/bin/env crystal
# community.general.zypper - subset port (issue #1677).
#
# Ported here: the module's AnsibleModule argument-validation surface
# (community.general 12.x zypper.py setup_module: argument_spec with
# name/state/type/aliases, the boolean parameters) and the
# `get_bin_path("zypper", required=True)` probe that get_cmd() runs
# before any package work - check mode included, because zypper.py
# declares supports_check_mode=True, so real RUNS the module under
# --check instead of skipping it. A host without the zypper binary
# therefore fails the task with real's
# `Failed to find required executable "zypper" in paths: ...` - the
# observable surface of chkpnt.mailserver's install.yml on an Ubuntu
# host, where this engine used to answer the zypper task with a graceful
# unavailable-module "skipping:" plus the end-of-run engine-limit exit 4
# (real fails the play there, exit 2, and never reaches the tasks below).
#
# NOT ported (a plain ok/changed=false after a successful probe, see
# KNOWN_MISSING.md): the package inventory and install/remove/upgrade
# work behind package_present()/package_absent() - real drives zypper
# against a real openSUSE package database; this engine targets Ubuntu
# and RHEL-family hosts only. Also unported are the three guards real's
# main()/package_absent() raise BEFORE get_cmd() is ever reached
# ("Can not dist-upgrade specific packages.", the absent-prefix
# combination and the URL/patch removal checks) - they need a zypper-less
# host to observe only when a task also carries those shapes.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  class ZypperPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # setup_module()'s argument_spec, name => aliases (the unsupported-
    # parameter message renders the names and the aliases sorted).
    SPEC = {
      "name"                  => %w[pkg],
      "state"                 => %w[],
      "type"                  => %w[],
      "extra_args_precommand" => %w[],
      "disable_gpg_check"     => %w[],
      "auto_import_keys"      => %w[],
      "disable_recommends"    => %w[],
      "force"                 => %w[],
      "force_resolution"      => %w[],
      "update_cache"          => %w[refresh],
      "oldpackage"            => %w[],
      "extra_args"            => %w[],
      "allow_vendor_change"   => %w[],
      "replacefiles"          => %w[],
      "clean_deps"            => %w[],
      "simple_errors"         => %w[],
      "quiet"                 => %w[],
      "skip_post_errors"      => %w[],
    }

    # Live-verified against ansible-core 2.21.6 + community.general
    # 12.5.0: "value of state must be one of: absent, installed, latest,
    # present, removed, dist-upgrade, got: banana" (declaration order).
    STATE_CHOICES = %w[absent installed latest present removed dist-upgrade]
    TYPE_CHOICES  = %w[package patch pattern product srcpackage application]

    BOOL_PARAMS = %w[
      disable_gpg_check auto_import_keys disable_recommends force
      force_resolution update_cache oldpackage allow_vendor_change
      replacefiles clean_deps simple_errors quiet skip_post_errors
    ]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      # get_cmd()'s get_bin_path("zypper", required=True): every package
      # action, and check mode too, probes the binary before touching the
      # package database. The probe is `command -v` because a shell has
      # to search $PATH the way get_bin_path does.
      if remote_exec("command -v zypper", force_shell: true)[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("zypper"))
      end

      # Post-probe surface unported (see header): every package action
      # answers a plain ok here.
      PluginResult.new(changed: false, failed: false)
    end

    # AnsibleModule validation, in ArgumentSpecValidator#validate order:
    # required arguments -> types -> choices -> unsupported. All of it
    # precedes the executable probe in real.
    private def validate_arguments : PluginResult?
      if err = validate_required
        return err
      end

      if err = validate_types
        return err
      end

      if err = validate_choices
        return err
      end

      validate_unsupported
    end

    private def validate_required : PluginResult?
      return nil if present_with_alias?("name")
      missing_required_error(["name"])
    end

    private def validate_types : PluginResult?
      BOOL_PARAMS.each do |param|
        next unless raw = @params[param]?
        # check_type_bool passes an explicit null through unchanged (only
        # a non-bool-convertible STRING fails there).
        next if explicit_null_param?(param)
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end
      nil
    end

    private def validate_choices : PluginResult?
      str_choice_specs = {
        "state" => STATE_CHOICES,
        "type"  => TYPE_CHOICES,
      }
      str_choice_specs.each do |param, allowed|
        next unless raw = @params[param]?
        # validate_argument_values ignores an explicit null.
        next if explicit_null_param?(param)
        next if allowed.includes?(raw)
        return choices_error(param, allowed, raw)
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error(@params["_module_name"]? || "community.general.zypper", unsupported, SPEC)
    end

    # An alias and its canonical name are the same parameter to the
    # validator's presence checks, so `pkg:` counts as `name:`.
    private def present_with_alias?(param : String) : Bool
      return true if @params[param]?
      (SPEC[param]? || %w[]).any? { |alias_name| @params[alias_name]? }
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ZypperPlugin.new(config)
plugin.run

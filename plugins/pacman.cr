#!/usr/bin/env crystal
# community.general.pacman - subset port (issue #1583).
#
# Ported here: the module's AnsibleModule argument-validation surface
# (community.general 12.x pacman.py setup_module: argument_spec,
# required_one_of, mutually_exclusive) and the
# `get_bin_path(p["executable"], True)` probe Pacman.__init__ runs
# before ANY package work, check mode included. A host without the
# pacman binary therefore fails the task with real's
# `Failed to find required executable "pacman" in paths: ...` - the
# observable surface of jpedrodelacerda.yay's Ubuntu run, where this
# engine used to answer the pacman task with a graceful
# unavailable-module "skipping:" plus the end-of-run engine-limit exit 4
# (real fails the play there, exit 2).
#
# NOT ported (a plain ok/changed=false after a successful probe, see
# KNOWN_MISSING.md): the package inventory and install/remove/upgrade
# work behind run() - real drives `pacman --print-format` etc. against a
# real Arch package database; this engine targets Ubuntu and RHEL-family
# hosts only.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  class PacmanPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # setup_module()'s argument_spec, name => aliases (the unsupported-
    # parameter message renders the names and the aliases sorted).
    SPEC = {
      "name"                    => %w[pkg package],
      "state"                   => %w[],
      "force"                   => %w[],
      "remove_nosave"           => %w[],
      "executable"              => %w[],
      "extra_args"              => %w[],
      "upgrade"                 => %w[],
      "upgrade_extra_args"      => %w[],
      "update_cache"            => %w[],
      "update_cache_extra_args" => %w[],
      "reason"                  => %w[],
      "reason_for"              => %w[],
    }

    # Live-verified against ansible-core 2.21.6 + community.general
    # 12.5.0: "value of state must be one of: present, installed, latest,
    # absent, removed, got: banana".
    STATE_CHOICES      = %w[present installed latest absent removed]
    REASON_CHOICES     = %w[explicit dependency]
    REASON_FOR_CHOICES = %w[new all]

    BOOL_PARAMS = %w[force remove_nosave upgrade update_cache]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      # Pacman.__init__'s get_bin_path(executable, required=True): every
      # state, and check mode too, probes the binary before touching the
      # package database. A task-level `executable:` overrides the
      # "pacman" default exactly like real's argument_spec.
      executable = @params["executable"]? || "pacman"
      # The probe is `command -v` because a shell has to search $PATH the
      # way get_bin_path does; quote_arg keeps a user-supplied executable
      # value inert instead of letting it run as shell syntax.
      probe = remote_exec("command -v #{Shell.quote_arg(executable)}", force_shell: true)
      if probe[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message(executable))
      end

      # Post-probe surface unported (see header): every package action
      # answers a plain ok here.
      PluginResult.new(changed: false, failed: false)
    end

    # AnsibleModule validation, in ArgumentSpecValidator#validate order:
    # mutually_exclusive -> required_one_of -> types -> choices ->
    # unsupported. All of it precedes the executable probe in real.
    private def validate_arguments : PluginResult?
      if err = validate_mutually_exclusive
        return err
      end

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

    private def validate_mutually_exclusive : PluginResult?
      return nil unless present_with_alias?("name") && @params["upgrade"]?
      PluginResult.new(changed: false, failed: true,
        msg: "parameters are mutually exclusive: name|upgrade")
    end

    private def validate_required : PluginResult?
      return nil if present_with_alias?("name") || @params["update_cache"]? || @params["upgrade"]?
      PluginResult.new(changed: false, failed: true,
        msg: "one of the following is required: name, update_cache, upgrade")
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
        "state"      => STATE_CHOICES,
        "reason"     => REASON_CHOICES,
        "reason_for" => REASON_FOR_CHOICES,
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
      unsupported_params_error("pacman", unsupported, SPEC)
    end

    # An alias and its canonical name are the same parameter to the
    # validator's presence checks, so `package:` counts as `name:`.
    private def present_with_alias?(param : String) : Bool
      return true if @params[param]?
      (SPEC[param]? || %w[]).any? { |alias_name| @params[alias_name]? }
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PacmanPlugin.new(config)
plugin.run

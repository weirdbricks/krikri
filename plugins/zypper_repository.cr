#!/usr/bin/env crystal
# community.general.zypper_repository - subset port (issue #1677).
#
# zypper_repository.py declares supports_check_mode=False, so under
# --check ansible-core's basic.py answers the task with its own check-mode
# skip ("remote module (community.general.zypper_repository) does not
# support check mode"), after argument validation and before main() runs.
# This plugin reproduces that gate.
#
# In both modes the ported surface starts with the module's AnsibleModule
# argument validation (community.general 12.x zypper_repository.py
# setup_module: argument_spec, required_one_of, the boolean/priority
# types). Outside check mode it continues with the
# `get_bin_path("zypper", required=True)` probe get_zypper_version() runs
# before any repository work, so a host without the zypper binary fails
# with real's
# `Failed to find required executable "zypper" in paths: ...`. Both are
# what chkpnt.mailserver's install.yml (which writes the FQCN spelling)
# observes on an Ubuntu host, where this engine used to answer the task
# with a graceful unavailable-module "skipping:" AND register it for the
# end-of-run engine-limit exit 4 - the "uses unimplemented plugin" line
# and exit code 4 real never printed.
#
# NOT ported (a plain ok/changed=false after a successful probe, see
# KNOWN_MISSING.md): the addrepo/removerepo/refresh work behind main() -
# real drives zypper against a real openSUSE repository database; this
# engine targets Ubuntu and RHEL-family hosts only. Also unported are
# main()'s own argument guards (state=present without repo, a .repo URL's
# fetch, ...): they need a zypper-present host to observe.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  class ZypperRepositoryPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # setup_module()'s argument_spec, name => aliases (the unsupported-
    # parameter message renders the names and the aliases sorted).
    SPEC = {
      "name"               => %w[],
      "repo"               => %w[],
      "state"              => %w[],
      "runrefresh"         => %w[],
      "description"        => %w[],
      "disable_gpg_check"  => %w[],
      "autorefresh"        => %w[refresh],
      "priority"           => %w[],
      "enabled"            => %w[],
      "overwrite_multiple" => %w[],
      "auto_import_keys"   => %w[],
    }

    # Live-verified against ansible-core 2.21.6 + community.general
    # 12.5.0: "value of state must be one of: present, absent, got:
    # banana" (declaration order).
    STATE_CHOICES = %w[present absent]

    # The spec's TYPE-check order is its declaration order, not a
    # kinds-grouped one: `priority: banana` alongside `enabled: banana`
    # fails on priority first (live-verified on 2.21.6).
    TYPED_PARAMS = {
      "runrefresh"         => :bool,
      "disable_gpg_check"  => :bool,
      "autorefresh"        => :bool,
      "priority"           => :int,
      "enabled"            => :bool,
      "overwrite_multiple" => :bool,
      "auto_import_keys"   => :bool,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      # basic.py's supports_check_mode gate: validation ran (so a bogus
      # state still fails above), then the module body never does.
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.general.zypper_repository"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true,
          omit_changed: true, key_order: ["skipped", "msg"])
      end

      # get_zypper_version()'s get_bin_path("zypper", required=True)
      # probe, ahead of any repository work.
      if remote_exec("command -v zypper", force_shell: true)[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("zypper"))
      end

      # Post-probe surface unported (see header): every repository action
      # answers a plain ok here.
      PluginResult.new(changed: false, failed: false)
    end

    # AnsibleModule validation, in ArgumentSpecValidator#validate order:
    # required_one_of -> types -> choices -> unsupported. All of it
    # precedes basic.py's check-mode gate in real. required_one_of=[["state",
    # "runrefresh"]] needs no check: both members carry a default
    # ("present"/false) and real applies defaults before that pass.
    private def validate_arguments : PluginResult?
      if err = validate_types
        return err
      end

      if err = validate_choices
        return err
      end

      validate_unsupported
    end

    private def validate_types : PluginResult?
      TYPED_PARAMS.each do |param, kind|
        raw = @params[param]?
        next unless raw
        # check_type_bool/check_type_int pass an explicit null through
        # unchanged (only a non-convertible STRING fails there).
        next if explicit_null_param?(param)
        case kind
        when :bool
          next if bool_convertible?(raw)
          return bool_type_error(param, raw)
        else
          next if raw.strip.to_i?
          return int_type_error(param, raw)
        end
      end
      nil
    end

    private def validate_choices : PluginResult?
      raw = @params["state"]?
      if raw && !explicit_null_param?("state") && !STATE_CHOICES.includes?(raw)
        return choices_error("state", STATE_CHOICES, raw)
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error(@params["_module_name"]? || "community.general.zypper_repository", unsupported, SPEC)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ZypperRepositoryPlugin.new(config)
plugin.run

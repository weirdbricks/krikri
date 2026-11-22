#!/usr/bin/env crystal
# community.general.pkgng - subset port (issue #1679).
#
# onelove-roles.freebsd-consul-template's first task calls `pkgng:` on
# Ubuntu. ansible-core resolves the bare name to community.general.pkgng
# (its builtin runtime redirects the ansible.builtin. spelling too) and
# real RUNS it; its main() calls
# `module.get_bin_path("pkg", True)` before any package work - check
# mode included - so the task fatals with
# `Failed to find required executable "pkg" in paths: ...` and the play
# stops there (rc=2). Without this plugin krikri answered the task with
# the graceful unavailable-module "skipping:" and ran on into the role's
# later tasks and its handler, finishing rc=4.
#
# Ported: the AnsibleModule argument-validation surface (main()'s
# argument_spec and mutually_exclusive) and the required `pkg` probe.
#
# NOT ported (a plain ok/changed=false after a successful probe, see
# KNOWN_MISSING.md): pkgng_older_than and the install/remove/upgrade/
# annotation/autoremove work behind it - real drives `pkg info`,
# `pkg install` etc. against a real FreeBSD package database, and this
# engine targets Ubuntu and RHEL-family hosts only.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  class PkgngPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # main()'s argument_spec, name => aliases (the unsupported-parameter
    # message renders the names and the aliases sorted).
    SPEC = {
      "state"        => %w[],
      "name"         => %w[pkg],
      "cached"       => %w[],
      "ignore_osver" => %w[],
      "annotation"   => %w[],
      "pkgsite"      => %w[],
      "rootdir"      => %w[],
      "chroot"       => %w[],
      "jail"         => %w[],
      "autoremove"   => %w[],
      "use_globs"    => %w[],
    }

    STATE_CHOICES = %w[present latest absent]
    BOOL_PARAMS   = %w[cached ignore_osver autoremove use_globs]
    DIR_PARAMS    = %w[rootdir chroot jail]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      # main()'s get_bin_path("pkg", required=True), which real runs
      # before its version probe and every package action. pkgng has no
      # executable: option, so the name is fixed.
      unless find_required_binary("pkg")
        return PluginResult.new(changed: false, failed: true,
          msg: PluginHelpers::GetBinPath.missing_executable_error("pkg", @bin_searched_paths))
      end

      # Post-probe surface unported (see header): every package action
      # answers a plain ok here.
      PluginResult.new(changed: false, failed: false)
    end

    # ArgumentSpecValidator#validate appends its error messages in this
    # order and AnsibleModule only ever surfaces errors[0], so the first
    # failing check wins; unsupported parameters are reported last (the
    # validator collects them up front but appends the error at the end).
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
      return nil if DIR_PARAMS.count { |param| provided?(param) } < 2
      PluginResult.new(changed: false, failed: true,
        msg: "parameters are mutually exclusive: #{DIR_PARAMS.join("|")}")
    end

    # check_required_arguments tests only whether the key is present, so
    # an explicit null passes here and fails later (real's own
    # `name:` null still reaches the pkg probe).
    private def validate_required : PluginResult?
      return nil if @params.has_key?("name") || @params.has_key?("pkg")
      missing_required_error(%w[name])
    end

    private def validate_types : PluginResult?
      BOOL_PARAMS.each do |param|
        next unless raw = @params[param]?
        # check_type_bool passes an explicit null through unchanged.
        next if explicit_null_param?(param)
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end
      nil
    end

    private def validate_choices : PluginResult?
      return nil unless raw = @params["state"]?
      return nil if explicit_null_param?("state")
      return nil if STATE_CHOICES.includes?(raw)
      choices_error("state", STATE_CHOICES, raw)
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("pkgng", unsupported, SPEC)
    end

    # check_mutually_exclusive's count_terms treats a None value as
    # absent; an empty string is still present.
    private def provided?(param : String) : Bool
      @params.has_key?(param) && !explicit_null_param?(param)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PkgngPlugin.new(config)
plugin.run

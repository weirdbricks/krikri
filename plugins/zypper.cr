#!/usr/bin/env crystal
# community.general.zypper - probe-only port (issue #1850).
#
# billyrayvalentine.susefirewall's first task is a plain `zypper:` install.
# Under --check on a Rocky host real ansible executes
# community.general.zypper, whose command builder calls
# get_bin_path("zypper", required=True) before any package work - so real
# fails the task with
# `Failed to find required executable "zypper" in paths: ...` and the play
# stops. krikri had no zypper plugin, so the same task took the graceful
# unavailable-module skip (recap skipped=1) and the play continued to the
# next task, ending in exit 4 with a "uses unimplemented plugin: zypper"
# line.
#
# Ported here: the module's AnsibleModule argument-validation surface and
# the get_bin_path probe, including main()'s branches that decide whether
# the probe runs at all. A host without zypper now fails exactly like real.
#
# NOT ported: every zypper command behind a successful probe (the
# package/pattern/patch/product state machine and the XML result shapes).
# SUSE sits outside this engine's Ubuntu/RHEL-family target range
# (KNOWN_MISSING.md), and the probe failure is the whole observable surface
# on those hosts. On a host that HAS zypper a task answers ok/changed=false
# where real reports the real work - revisit if a round lands on a SUSE
# host.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  class ZypperPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # community.general.zypper's argument_spec, name => aliases, in
    # declaration order.
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

    STATE_CHOICES = %w[absent installed latest present removed dist-upgrade]
    TYPE_CHOICES  = %w[package patch pattern product srcpackage application]

    protected def bool_params : Array(String)
      %w[disable_gpg_check auto_import_keys disable_recommends force
        force_resolution update_cache oldpackage allow_vendor_change
        replacefiles clean_deps simple_errors quiet skip_post_errors]
    end

    # Real resolves the alias to the canonical key before argspec
    # validation, so a bad `refresh:` value is reported as update_cache.
    protected def bool_param_aliases : Hash(String, String)
      {"refresh" => "update_cache"}
    end

    def execute : PluginResult
      if error = validate_arguments
        return error
      end

      names = requested_names
      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)

      # main(): the repository refresh runs first, and only outside check
      # mode, so its probe can be the first failure for a bad invocation
      # that would otherwise be refused later (a specific-package
      # dist-upgrade, for instance).
      if update_cache? && !check_mode
        if error = probe_zypper
          return error
        end
      end

      return update_all if update_all?(names, state)
      return dist_upgrade_refusal if state == "dist-upgrade"

      packages, urls = split_names(names, remove: absent?(state))
      return absent_result(packages, urls) if absent?(state)

      present_result(packages, urls)
    end

    private def absent?(state : String) : Bool
      state == "absent" || state == "removed"
    end

    private def update_cache? : Bool
      true?(@params["update_cache"]? || @params["refresh"]?)
    end

    private def update_all?(names : Array(String), state : String) : Bool
      names == ["*"] && (state == "latest" || state == "dist-upgrade")
    end

    # package_update_all: its get_cmd probe is the first zypper contact.
    private def update_all : PluginResult
      probe_zypper || success
    end

    private def dist_upgrade_refusal : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Can not dist-upgrade specific packages.")
    end

    # package_absent's own refusals all precede get_installed_state, whose
    # command builder is the one that probes for zypper (even for an empty
    # package list, which it queries before the "nothing to remove" return).
    private def absent_result(packages : Array(String), urls : Array(String)) : PluginResult
      if packages.any?(&.starts_with?('+'))
        return PluginResult.new(changed: false, failed: true,
          msg: "Can not combine '+' prefix with state=remove/absent.")
      end
      return PluginResult.new(changed: false, failed: true, msg: "Can not remove via URL.") unless urls.empty?
      if @params["type"]? == "patch"
        return PluginResult.new(changed: false, failed: true, msg: "Can not remove patches.")
      end
      probe_zypper || success
    end

    # package_present: nothing to install/remove and no URL to fetch means
    # no zypper invocation at all, so no probe either.
    private def present_result(packages : Array(String), urls : Array(String)) : PluginResult
      return success if packages.empty? && urls.empty?
      probe_zypper || success
    end

    # AnsibleModule construction: unsupported params, required params,
    # bool/choices conversion - all of it before main() ever reaches the
    # zypper binary.
    private def validate_arguments : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("zypper", unsupported, SPEC)
      end

      unless @params["name"]? || @params["pkg"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: name")
      end

      begin
        validate_bool_params!
      rescue error : BoolParamError
        return PluginResult.new(changed: false, failed: true, msg: error.message || "")
      end

      state = @params["state"]?
      if state && !STATE_CHOICES.includes?(state)
        return choices_error("state", STATE_CHOICES, state)
      end

      type = @params["type"]?
      if type && !TYPE_CHOICES.includes?(type)
        return choices_error("type", TYPE_CHOICES, type)
      end
    end

    # get_want_state: anything URL-shaped is fetched rather than named,
    # everything else is a package spec. The returned list keeps the
    # leading +/- some specs carry.
    private def split_names(names : Array(String), remove : Bool) : {Array(String), Array(String)}
      packages = [] of String
      urls = [] of String
      names.each do |name|
        if name.includes?("://") || name.ends_with?(".rpm")
          urls << name
        else
          stripped = name.strip
          prefix = stripped[0]?
          if prefix != '-' && prefix != '+'
            stripped = (remove ? "-" : "+") + stripped
          end
          packages << stripped
        end
      end
      {packages, urls}
    end

    private def requested_names : Array(String)
      raw = @params["name"]? || @params["pkg"]? || ""
      raw.split(',').reject(&.empty?)
    end

    private def probe_zypper : PluginResult?
      return nil if find_required_binary("zypper")
      PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error("zypper", @bin_searched_paths))
    end

    # Post-probe surface unported (see header): the module reports its own
    # unchanged result here.
    private def success : PluginResult
      PluginResult.new(changed: false, failed: false)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ZypperPlugin.new(config)
plugin.run

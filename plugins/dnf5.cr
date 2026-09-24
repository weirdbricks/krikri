#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/rpm_package"

module Krikri
  # DNF5 plugin - manages packages with the dnf5 package manager.
  # Compatible with Ansible's ansible.builtin.dnf5 module (added in
  # ansible-core 2.19).
  #
  # Like plugins/dnf.cr, the install/remove/upgrade machinery lives in the
  # shared PluginHelpers::RpmPackage module; the per-plugin inputs are the
  # backend binary name ("dnf5"), the state=latest upgrade verb ("dnf5"
  # renamed `update` to `upgrade`), the `list` query flag form (dnf5 takes
  # `--installed`/`--available`/`--upgrades` FLAGS where dnf/yum take those
  # words positionally), and this plugin's own argument-spec validation.
  # dnf5 shares ansible-core's `yumdnf_argument_spec` but ADDS
  # `auto_install_module_deps`/`best` and does NOT accept dnf's
  # `use_backend` or the retired `install_repoquery`.
  #
  # Live-verified against real ansible-core 2.21.4 on Fedora 41 (dnf5
  # 5.2.17): the whole option matrix is checked side-by-side in
  # testing/dnf5/dnf5_options.yml.
  class Dnf5Plugin < BasePlugin
    include PluginHelpers::RpmPackage

    private def pkg_manager_binary : String
      "dnf5"
    end

    # dnf5 dropped the yum/dnf `update` verb in favor of `upgrade`.
    private def update_verb : String
      "upgrade"
    end

    # dnf5's `list` takes flags (--installed/--available/--upgrades/
    # --extras/--obsoletes) where dnf/yum take the same words as
    # positional subcommands; any other scalar query is still a positional
    # package-spec. `list: repos` is not reproduced (real builds it from a
    # RepoQuery; the dnf5 CLI form differs and no package role uses it).
    private def list_args(query : String) : String
      flag = case query
             when "installed" then "--installed"
             when "available" then "--available"
             when "extras"    then "--extras"
             when "obsoletes" then "--obsoletes"
             when "updates", "upgrades"
               "--upgrades"
             end
      flag ? "list #{flag}" : "list #{shell_single_quote(query)}"
    end

    def execute : PluginResult
      if failure = arg_spec_rejection
        return failure
      end

      normalize_best_param
      normalize_expire_cache_alias

      if list_result = list_query_result
        return list_result
      end

      names = parse_package_names

      # `autoremove: true` with no `name:` (real dnf5's own documented usage
      # - "Autoremove unneeded packages installed as dependencies") removes
      # the leaf packages regardless of `state`, so short-circuit before the
      # empty-names check (which would otherwise report a missing `name`).
      return handle_autoremove if true?(@params["autoremove"]?) && names.empty?

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

      dispatch_state(names, state)
    end

    # ----- argument-spec validation (split for readability) -----

    private def arg_spec_rejection : PluginResult?
      unsupported_rejection || bool_rejection || null_list_rejection || mutual_exclusion_rejection
    end

    # Real dnf5's supported set = shared yumdnf_argument_spec + auto_install_module_deps
    # + best, and (unlike dnf) WITHOUT use_backend / install_repoquery. The
    # trailing "(expire-cache, pkg)" is real's aliases appended to the list.
    private def unsupported_rejection : PluginResult?
      dnf5_supported = {"allow_downgrade", "allowerasing", "auto_install_module_deps",
                        "autoremove", "best", "bugfix", "cacheonly", "conf_file",
                        "disable_excludes", "disable_gpg_check", "disable_plugin",
                        "disablerepo", "download_dir", "download_only", "enable_plugin",
                        "enablerepo", "exclude", "install_weak_deps", "installroot",
                        "list", "lock_timeout", "name", "nobest", "pkg", "releasever",
                        "security", "skip_broken", "sslverify", "state", "update_cache",
                        "update_only", "validate_certs", "expire-cache"}
      dnf5_internal = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| dnf5_supported.includes?(k) || dnf5_internal.includes?(k) || k.starts_with?("_") }
      return nil if unsupported.empty?

      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Unsupported parameters for (ansible.builtin.dnf5) module: #{unsupported.sort.join(", ")}. " \
             "Supported parameters include: " \
             "allow_downgrade, allowerasing, auto_install_module_deps, autoremove, best, bugfix, " \
             "cacheonly, conf_file, disable_excludes, disable_gpg_check, disable_plugin, disablerepo, " \
             "download_dir, download_only, enable_plugin, enablerepo, exclude, install_weak_deps, " \
             "installroot, list, lock_timeout, name, nobest, releasever, security, skip_broken, " \
             "sslverify, state, update_cache, update_only, validate_certs (expire-cache, pkg)."
      )
    end

    # Real AnsibleModule fails a bool-typed arg given a non-boolean string
    # (see plugins/dnf.cr for the full story). The valid-boolean list in
    # real's message is a Python set serialized in arbitrary order, so the
    # ELEMENTS (not their order) are what must match.
    private def bool_rejection : PluginResult?
      dnf5_bool_params = {"allow_downgrade", "allowerasing", "auto_install_module_deps",
                          "autoremove", "best", "bugfix", "cacheonly", "disable_gpg_check",
                          "download_only", "install_weak_deps", "nobest", "security",
                          "skip_broken", "sslverify", "update_cache", "update_only",
                          "validate_certs", "expire-cache"}
      valid_booleans = {"0", "1", "true", "off", "yes", "t", "false", "on", "f", "n", "y", "no"}
      bad = @params.select { |k, v| dnf5_bool_params.includes?(k) && !valid_booleans.includes?(v.downcase) }.keys.sort!
      return nil if bad.empty?

      PluginResult.new(
        changed: false,
        failed: true,
        msg: "argument '#{bad.first}' is of type str and we were unable to convert to bool: " \
             "The value '#{@params[bad.first]}' is not a valid boolean. " \
             "Valid booleans include: 0, 1, 'y', '0', 'off', 't', 'n', '1', 'f', 'true', 'on', 'false', 'yes', 'no'"
      )
    end

    # Real AnsibleModule's `type: list` coercion fails an EXPLICIT None
    # with its generic list-conversion message; an omitted param and an
    # empty string both coerce to an empty list and pass (see plugins/
    # dnf.cr's identical gate for the story).
    private def null_list_rejection : PluginResult?
      nulls = {"name", "enablerepo", "disablerepo", "exclude"}.select { |key| explicit_null_param?(key) }.sort!
      return nil if nulls.empty?

      PluginResult.new(
        changed: false,
        failed: true,
        msg: "argument '#{nulls.first}' is of type NoneType and we were unable to convert to list: " \
             "<class 'NoneType'> cannot be converted to a list"
      )
    end

    # Real AnsibleModule enforces the shared yumdnf `mutually_exclusive`
    # pairs after coercion: name|list and best|nobest, each firing with the
    # standard message only when BOTH members are non-empty.
    private def mutual_exclusion_rejection : PluginResult?
      name = @params["name"]?
      list = @params["list"]?
      if name && !name.strip.empty? && list && !list.strip.empty?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: name|list")
      end
      best = @params["best"]?
      nobest = @params["nobest"]?
      if best && !best.strip.empty? && nobest && !nobest.strip.empty?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: best|nobest")
      end
      nil
    end

    # ----- dnf5-specific parameter normalization -----

    # `best` and `nobest` share one meaning (the libdnf5 solver's "best"
    # flag) and are mutually exclusive, so normalize `best` onto the
    # `nobest` handling the shared build_dnf_options implements.
    private def normalize_best_param : Nil
      best = @params["best"]?
      return if best.nil? || best.strip.empty?
      @params["nobest"] = true?(best) ? "false" : "true"
    end

    # `update_cache:` is aliased to `expire-cache:` in the shared spec; the
    # shared empty-names handler only reads `update_cache`.
    private def normalize_expire_cache_alias : Nil
      ec = @params["expire-cache"]?
      return if ec.nil?
      existing = @params["update_cache"]?
      @params["update_cache"] = ec if existing.nil? || existing.strip.empty?
    end

    private def dispatch_state(names : Array(String), state : String) : PluginResult
      options = build_dnf_options

      # Real dnf5 sets conf.skip_unavailable for the advisory-filtered
      # security/bugfix update path, so a package with no applicable
      # advisory is skipped (ok/changed:false) rather than hard-failing
      # "No match for argument ... in selected advisories"; the dnf5 CLI
      # needs an explicit --skip-unavailable to reproduce that.
      options += " --skip-unavailable" if true?(@params["security"]?) || true?(@params["bugfix"]?)

      case state
      when "present"
        handle_install(names, options)
      when "absent"
        handle_remove(names, options)
      else
        handle_update(names, options)
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Dnf5Plugin.new(config)
plugin.run

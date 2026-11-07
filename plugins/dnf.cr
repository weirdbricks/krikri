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
  # - nobest: Highest-version-or-fail handling (2.19's shared yumdnf
  #   argument spec has BOTH `best` and `nobest` - `best:` is a
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
  # - lock_timeout: Accepted as a no-op for the dnf backend, matching
  #   Ansible's own dnf.py (the dnf python API handles lock
  #   waiting internally; only the retired yum backend consumed it)
  # - use_backend: Which backend module Ansible would dispatch to
  #   (auto/dnf/yum/yum4/dnf4/dnf5); validated against Ansible's
  #   choice list, then treated as a no-op since krikri has a single
  #   dnf implementation to select between
  # - validate_certs: Accepted as a no-op; Ansible only applies it
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
    # ansible.builtin.dnf's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.dnf). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[allow_downgrade allowerasing autoremove best bugfix cacheonly disable_gpg_check
        download_only install_weak_deps nobest security skip_broken
        sslverify update_cache update_only validate_certs]
    end

    protected def bool_param_aliases : Hash(String, String)
      {
        "expire-cache" => "update_cache",
      }
    end

    # These default to None in Ansible's argspec, so an explicit null skips
    # type validation there (see BasePlugin#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[best nobest]
    end

    include PluginHelpers::RpmPackage

    private def pkg_manager_binary : String
      "dnf"
    end

    # Whether the request resolved to the dnf5 backend. Ansible's `dnf:`
    # ACTION plugin rewrites the module
    # name from use_backend (default "auto") - and for auto/yum resolves
    # the host's ansible_pkg_mgr fact, running the dnf5 MODULE on a host
    # whose package manager is dnf5 (Fedora 41+) and the dnf4 module
    # everywhere else. The two backends' registered results differ in
    # key order (see RpmPackage's shape notes), so this plugin resolves
    # the same way: an explicit use_backend wins, then the pkg_mgr fact
    # when gathered, then a direct probe of what /usr/bin/dnf (or
    # /usr/bin/microdnf) symlinks to - real pkg_mgr.py's own
    # _check_rh_versions disambiguation.
    @dnf5_backend = false

    private def resolve_backend : Nil
      use = @params["use_backend"]? || "auto"
      @dnf5_backend = case use
                      when "dnf5"
                        true
                      when "auto", "yum", "yum4"
                        # Same pkg_mgr fact the action-level resolution above
                        # dispatches on (RpmPackage#pkg_mgr_fact): the gathered
                        # fact, or the on-demand detection when the play never
                        # gathered - so a fact-less dnf5 host keeps the dnf5
                        # result shapes the old standalone symlink probe produced.
                        pkg_mgr_fact == "dnf5"
                      else
                        false
                      end
    end

    # The module name the backend's own argument-spec error carries. Real's
    # dnf ACTION plugin rewrites the delegation target to
    # 'ansible.legacy.' + backend before _execute_module
    # (plugins/action/dnf.py: "eliminate collisions with collections search
    # while still allowing local override"), so the module's argspec error
    # names ansible.legacy.dnf (or ansible.legacy.dnf5) no matter how the
    # task spelled `dnf:` - live-verified vs 2.19.11: the bare,
    # ansible.builtin.- and ansible.legacy.-qualified spellings all print
    # (ansible.legacy.dnf), and use_backend: dnf5 prints
    # (ansible.legacy.dnf5).
    private def backend_module_name : String
      @dnf5_backend ? "ansible.legacy.dnf5" : "ansible.legacy.dnf"
    end

    private def transaction_key_order : Array(String)
      @dnf5_backend ? DNF5_TRANSACTION_ORDER : DNF_TRANSACTION_ORDER
    end

    private def list_result_key_order : Array(String)
      @dnf5_backend ? DNF5_LIST_ORDER : DNF4_LIST_ORDER
    end

    # Ansible.builtin.dnf's argument-spec validation rejects ANY
    # parameter outside its argument_spec at module-arg validation,
    # before any module code runs - found via the podman-diff
    # dnf_edge_cases N2 harness case (ansible-core rejected
    # krikri_not_a_dnf_param with the message below while this engine
    # silently ignored the unknown key and proceeded to the backend
    # failure). Message live-verified against ansible-core 2.19.11.
    # check_mode/diff_mode/_verbosity/_environment are engine-internal
    # keys injected by the executor, not part of Ansible's
    # argument_spec, so they are not rejected. use_backend is in the
    # dnf backend module's own argument_spec per dnf.py (2.19.11 lists
    # it in the supported-params message live) and stays accepted here.
    private def arg_spec_rejection : PluginResult?
      # Real's backend resolution runs before the module's own argument
      # validation (in real it IS the surrounding code - the dnf ACTION
      # plugin). Round 5310001: see RpmPackage#dnf_backend_resolution_failure.
      if failure = dnf_backend_resolution_failure
        return failure
      end

      # 2.21 dropped the retired `install_repoquery` from the shared
      # yumdnf spec (live-verified vs 2.21.6), so it left the supported
      # set here too.
      dnf_supported = {"allow_downgrade", "allowerasing", "autoremove", "bugfix",
                       "cacheonly", "conf_file", "disable_excludes", "disable_gpg_check",
                       "disable_plugin", "disablerepo", "download_dir", "download_only",
                       "enable_plugin", "enablerepo", "exclude",
                       "install_weak_deps", "installroot", "list", "lock_timeout",
                       "name", "best", "nobest", "releasever", "security", "skip_broken",
                       "sslverify", "state", "update_cache", "update_only",
                       "validate_certs", "use_backend", "expire-cache", "pkg"}
      dnf_internal = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      # Ansible collects unsupported params but reports them LAST in its
      # check order (mutually_exclusive -> required -> types -> choices ->
      # ... -> unsupported), so a bool-type error beats a typo'd parameter
      # (kpg:dnf chaos #42: install_weak_deps: ksjyws alongside escurity/
      # sttae failed with the bool error on real, not the unsupported one).
      # Compute the unsupported rejection here but return it only after
      # the shared checks below.
      unsupported_rejection : PluginResult? = nil
      if @dnf5_backend
        # Under the dnf5 backend the message is the dnf5 MODULE's own
        # argspec check, not dnf's: the action plugin strips use_backend
        # before delegating (it never reaches the backend module) and
        # dnf5's spec adds auto_install_module_deps - live-verified vs
        # 2.19.11 (`dnf: {use_backend: dnf5, <bogus>}` reports
        # (ansible.legacy.dnf5) with dnf5's list).
        dnf5_supported = {"allow_downgrade", "allowerasing", "auto_install_module_deps",
                          "autoremove", "best", "bugfix", "cacheonly", "conf_file",
                          "disable_excludes", "disable_gpg_check", "disable_plugin",
                          "disablerepo", "download_dir", "download_only", "enable_plugin",
                          "enablerepo", "exclude", "install_weak_deps",
                          "installroot", "list", "lock_timeout", "name", "nobest",
                          "releasever", "security", "skip_broken", "sslverify", "state",
                          "update_cache", "update_only", "validate_certs", "expire-cache", "pkg"}
        unsupported = @params.keys.reject { |k| dnf5_supported.includes?(k) || dnf_internal.includes?(k) || k.starts_with?("_") || k == "use_backend" }
        unless unsupported.empty?
          unsupported_rejection = PluginResult.new(
            changed: false,
            failed: true,
            msg: "Unsupported parameters for (#{backend_module_name}) module: #{unsupported.sort.join(", ")}. " \
                 "Supported parameters include: " \
                 "allow_downgrade, allowerasing, auto_install_module_deps, autoremove, best, bugfix, " \
                 "cacheonly, conf_file, disable_excludes, disable_gpg_check, disable_plugin, disablerepo, " \
                 "download_dir, download_only, enable_plugin, enablerepo, exclude, " \
                 "install_weak_deps, installroot, list, lock_timeout, name, nobest, releasever, security, " \
                 "skip_broken, sslverify, state, update_cache, update_only, validate_certs (expire-cache, pkg)."
          )
        end
        # fall through to the SHARED checks below (mutual exclusion, bool
        # conversion, the explicit-null list check): dnf5.py shares
        # yumdnf's argument_spec with dnf.py (live-verified vs 2.19.11),
        # so a use_backend: dnf5 task still fails an explicit-null
        # `name:` with the same NoneType message (etam.ipfs round
        # 29895333) instead of skipping validation to the backend run.
      else
        unsupported = @params.keys.reject { |k| dnf_supported.includes?(k) || dnf_internal.includes?(k) || k.starts_with?("_") }
        unless unsupported.empty?
          unsupported_sorted = unsupported.sort
          unsupported_rejection = PluginResult.new(
            changed: false,
            failed: true,
            msg: "Unsupported parameters for (#{backend_module_name}) module: #{unsupported_sorted.join(", ")}. " \
                 "Supported parameters include: " \
                 "allow_downgrade, allowerasing, autoremove, best, bugfix, cacheonly, conf_file, disable_excludes, " \
                 "disable_gpg_check, disable_plugin, disablerepo, download_dir, download_only, enable_plugin, " \
                 "enablerepo, exclude, install_weak_deps, installroot, list, lock_timeout, " \
                 "name, nobest, releasever, security, skip_broken, sslverify, state, update_cache, update_only, " \
                 "use_backend, validate_certs (expire-cache, pkg)."
          )
        end
      end

      if rejection = yumdnf_mutual_exclusion_rejection
        return rejection
      end

      # AnsibleModule type-converts every bool-typed argument_spec
      # param and fails the task on a non-boolean value at module setup -
      # now via the shared BasePlugin#validate_bool_params! (message
      # live-verified against ansible-core 2.19.11; the <class 'str'>
      # double-space wording this check used to pin came from 2.14).
      # Without it this engine accepted e.g. `disable_gpg_check:
      # sometimes` as a truthy value and ran the transaction anyway.
      # NOTE: mutually_exclusive validation fires BEFORE this (and before
      # list coercion) - see yumdnf_mutual_exclusion_rejection.
      validate_bool_params!

      # AnsibleModule's `type: list` argspec coercion fails an
      # EXPLICIT None with its generic list-conversion message (param
      # name substituted), while an omitted param and an empty string
      # both coerce to an empty list and pass - live-verified against
      # ansible-core 2.19.11 for each of dnf's four `type: list` params
      # (`use_backend: yum4` forced on a Debian host to reach argspec
      # validation at all). Round 900905 officel.httpd found the gap:
      # every loop item's `enablerepo: ~` default made
      # ansible-playbook fail the task while this engine silently
      # dropped the null and installed the packages anyway. The
      # explicit-null gate (not a plain empty-string check) is what
      # keeps an omitted param - and a legitimately empty string -
      # working exactly as before.
      dnf_list_params = {"name", "enablerepo", "disablerepo", "exclude"}
      null_list = dnf_list_params.select { |key| explicit_null_param?(key) }.sort!
      unless null_list.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "argument '#{null_list.first}' is of type NoneType and we were unable to convert to list: " \
               "<class 'NoneType'> cannot be converted to a list"
        )
      end

      # unsupported-params is reported only after every other spec check
      unsupported_rejection
    end

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      resolve_backend

      if failure = arg_spec_rejection
        return failure
      end

      # Argspec-choices validation (state, then use_backend - argument_spec
      # dict order decides, and yumdnf.py appends use_backend last) precedes
      # ALL module-body work, including list queries and yumdnf.py's own
      # autoremove sanity check. An explicit state must be checked before
      # anything else can return first: real ansible reports
      # "value of state must be one of: ..." even when `list:` would also
      # have produced a result. state's choice check only runs for an
      # explicit STRING value (an omitted state defaults to None, which
      # skips choices validation entirely; a non-string value keeps
      # reaching the type-shaped check below, preserving this plugin's
      # pre-existing behavior there).
      if explicit_state = @params["state"]?
        if explicit_state.is_a?(String) &&
           !["absent", "installed", "latest", "present", "removed"].includes?(explicit_state)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "value of state must be one of: absent, installed, latest, present, removed, got: #{explicit_state}"
          )
        end
      end

      # use_backend: Ansible's argument spec (dnf.py:
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

      # yumdnf.py's YumDnf.__init__ sanity check runs after the whole
      # argument-spec validation and before any module body - so even a
      # nameless autoremove task fails with this message on real ansible
      # instead of reaching the empty-name/autoremove handling below.
      if rejection = yumdnf_autoremove_rejection
        return rejection
      end

      if list_result = list_query_result
        return list_result
      end

      names = parse_package_names

      # `autoremove: true` with no `name:` is dnf's own documented usage
      # ("Autoremove unneeded packages installed as dependencies", dnf.py
      # EXAMPLES) - the yumdnf init check above already rejected a
      # contradicting explicit state, so state here is absent-or-omitted
      # and the transaction is `dnf autoremove`, not a missing-name error.
      # Same shape dnf5.cr already implements.
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

    # Ansible.builtin.dnf's module code goes through dnf's Python API
    # directly, which treats an `enablerepo:` naming a repo ID that isn't
    # configured on the host (e.g. `enablerepo: epel` with no epel-release
    # installed - buluma.elasticsearch_curator's own setup-RedHat.yml does
    # exactly this) as a warning, not a fatal error, and proceeds with
    # whatever repos ARE available. The raw `dnf` CLI this plugin shells
    # out to is stricter and hard-fails with "Error: Unknown repo: 'X'"
    # instead - found benchmarking round166's buluma.elasticsearch_curator
    # on Rocky 9.6 (krikri-playbook failed the task, ansible-playbook
    # installed successfully via whatever repos were already present).
    # Strip the offending --enablerepo=X flag(s) and retry rather than
    # failing the task, matching Ansible's lenient behavior.

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

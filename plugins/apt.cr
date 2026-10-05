#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/ansible_splitlines"
require "../src/krikri/plugin_helpers/apt_lock_retry"

module Krikri
  # APT Plugin - Debian/Ubuntu package management
  #
  # Parameters:
  #   name (optional): Package name or list of packages
  #   deb (optional): Path or URL to a local .deb file to install
  #   state (optional): present, absent, latest (default: present)
  #   update_cache (optional): Update apt cache before operation
  #   cache_valid_time (optional): Cache is valid for this many seconds
  #   check_mode (optional): Dry-run mode
  #
  #   The remaining real-Ansible apt module options (see the param
  #   parsing in #execute_inner for each one's mapping to the real
  #   module's behavior):
  #   allow_change_held_packages, allow_downgrade, allow_unauthenticated,
  #   auto_install_module_deps (no-op by architecture - a native Crystal
  #   plugin has no python3-apt dependency for it to govern),
  #   default_release, dpkg_options, fail_on_autoremove, force,
  #   force_apt_get (no-op by construction - this plugin always shells
  #   out to apt-get, it has no aptitude path to steer away from),
  #   install_recommends, only_upgrade, policy_rc_d, purge.
  #
  # Examples:
  #   apt:
  #     name: nginx
  #     state: present
  #     update_cache: yes
  #
  #   apt:
  #     name:
  #       - curl
  #       - wget
  #     state: present
  #
  #   apt:
  #     update_cache: yes
  class AptPlugin < BasePlugin
    include AptLockRetry
    include PluginHelpers::AnsibleArgValidation

    # Real apt.py's own argument_spec (bookworm's ansible-core 2.14,
    # the harness reference) - names mapped to their alias lists. Drives
    # the unsupported-param/choices/bool-type validation below the same
    # way AnsibleModule setup does.
    private APT_SPEC = {
      "state"                        => [] of String,
      "update_cache"                 => ["update-cache"],
      "update_cache_retries"         => [] of String,
      "update_cache_retry_max_delay" => [] of String,
      "cache_valid_time"             => [] of String,
      "purge"                        => [] of String,
      "package"                      => ["pkg", "name"],
      "deb"                          => [] of String,
      "default_release"              => ["default-release"],
      "install_recommends"           => ["install-recommends"],
      "force"                        => [] of String,
      "upgrade"                      => [] of String,
      "dpkg_options"                 => [] of String,
      "autoremove"                   => [] of String,
      "autoclean"                    => [] of String,
      "fail_on_autoremove"           => [] of String,
      "policy_rc_d"                  => [] of String,
      "only_upgrade"                 => [] of String,
      "force_apt_get"                => [] of String,
      "clean"                        => [] of String,
      "allow_unauthenticated"        => ["allow-unauthenticated"],
      "allow_downgrade"              => ["allow-downgrade", "allow-downgrades", "allow_downgrades"],
      "allow_change_held_packages"   => [] of String,
      "auto_install_module_deps"     => [] of String,
      "lock_timeout"                 => [] of String,
    }

    # ansible.builtin.apt's `type: bool` options, in the real
    # argument-spec declaration order (ansible-doc -j ansible.builtin.apt).
    protected def bool_params : Array(String)
      %w[allow_change_held_packages allow_downgrade allow_unauthenticated
        auto_install_module_deps autoclean autoremove clean
        fail_on_autoremove force force_apt_get install_recommends
        only_upgrade purge update_cache]
    end

    protected def bool_param_aliases : Hash(String, String)
      {
        "allow-downgrade"       => "allow_downgrade",
        "allow_downgrades"      => "allow_downgrade",
        "allow-downgrades"      => "allow_downgrade",
        "allow-unauthenticated" => "allow_unauthenticated",
        "install-recommends"    => "install_recommends",
        "update-cache"          => "update_cache",
      }
    end

    # install_recommends/update_cache default to None in Ansible's argspec,
    # so an explicit null skips type validation there (see
    # BasePlugin#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[install_recommends update_cache]
    end

    # apt.py's state choice list (2.14: includes build-dep and fixed).
    private APT_STATES = %w[absent build-dep fixed latest present]

    property? check_mode : Bool

    # Set true only when an `apt-get update` actually ran here and
    # genuinely moved the cache mtime (the same before/after stat pair
    # Ansible's get_updated_cache_time() diffs); surfaced as the
    # result's `cache_updated` key on EVERY exit path via #execute's
    # wrapper below - Ansible's apt module always includes the key
    # in exit_json, and the very common
    # `changed_when: apt_cache.cache_updated` idiom (hifis.gitlab's own
    # cache-refresh task) hard-fails with "object of type 'dict' has no
    # attribute 'cache_updated'" the moment a registered result lacks it.
    @cache_updated = false
    # early fail_json paths (before any cache work) carry no cache_updated key
    @omit_cache_updated = false
    # Real apt.py's get_updated_cache_time() epoch value - the apt lists
    # dir's mtime, read unconditionally at the top of every main() cache
    # pass and re-read after a real `apt-get update` - carried as
    # `cache_update_time` on the cache-only and install-path exits
    # (round-992002/992003 *_helper_install captures). The two keys
    # always travel together there, but cache_updated is backfilled
    # engine-wide by #execute while this one is attached only at the
    # exits real apt.py itself carries it on (remove/upgrade/deb exit
    # through their own exit_json calls and never gain either).
    @cache_update_time = 0

    # Real-Ansible apt module params this plugin threads into its apt-get
    # invocations (defaults mirror apt.py's argument_spec). Booleans are
    # parsed once here and read by the handle_* helpers below; the
    # tri-state `install_recommends` stays nil when unset so the OS
    # default (normally install-recommends=yes) applies untouched.
    @dpkg_options = "force-confdef,force-confold"
    @apt_get_bin : String? = nil
    @policy_rc_d : Int32? = nil
    @purge = false
    @force = false
    @fail_on_autoremove = false
    @only_upgrade = false
    @allow_unauthenticated = false
    @allow_downgrade = false
    @allow_change_held_packages = false
    @default_release : String? = nil
    @install_recommends : Bool? = nil
    @policy_rc_d_restore_failed = false

    # Internal spec seam (same underscore-prefixed family as
    # `_environment`): the policy-rc.d path is hardcoded to
    # Ansible's own `/usr/sbin/policy-rc.d` for real playbooks, but the
    # lifecycle spec needs to run it against a writable temp path since
    # the spec process is unprivileged. Never set by real playbooks.
    @policy_rc_d_path = "/usr/sbin/policy-rc.d"

    def execute : PluginResult
      result = execute_inner
      # an unhandled module exception (python-apt's SystemError) never reaches
      # exit_json, so its failure carries no cache_updated key
      result.extra["cache_updated"] = JSON.parse(@cache_updated.to_json) unless result.extra.has_key?("_ansible_error_detail") || @omit_cache_updated || result.msg.to_s.starts_with?("No package matching")
      result
    end

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute_inner : PluginResult
      # Ansible's apt module rejects ANY parameter outside its own
      # argument_spec at module-arg validation, before any action runs -
      # notably `use:`, which is a PACKAGE action-plugin parameter (the
      # action plugin consumes it to pick a backend and never forwards it
      # to the apt module), so `apt: {name: ..., use: no-such-backend}`
      # fails with "Unsupported parameters ... use" while this engine
      # silently ignored the unknown key and ran anyway. Found via the
      # podman-diff package_edge_cases P2 harness case; message live-
      # verified against ansible-core 2.19's own output for this exact
      # task. check_mode/diff_mode/_verbosity/_environment are engine-
      # internal keys injected by the executor (see build_plugin_config),
      # and _policy_rc_d_path is the spec seam above - none are part of
      # Ansible's argument_spec, so none are rejected. (_policy_rc_d_path
      # needs an explicit exemption: it is not in the shared INTERNAL
      # list because it is this plugin's spec seam alone, and the
      # policy_rc_d lifecycle specs pass it on every call.)
      unsupported = unsupported_param_keys(@params, APT_SPEC).reject { |key| key == "_policy_rc_d_path" }
      unless unsupported.empty?
        return unsupported_params_error(
          @params["_module_name"]? || "ansible.builtin.apt",
          unsupported, APT_SPEC,
        )
      end

      # apt.py's own mutually_exclusive=[['deb', 'package', 'upgrade']] -
      # checked at AnsibleModule setup, BEFORE anything else in main().
      # The message lists the WHOLE conflicting group sorted, not just
      # the members that were passed (live-verified: `name:` + `upgrade:`
      # yields "parameters are mutually exclusive: deb|package|upgrade"
      # even though no deb: was given). `upgrade` counts as given even
      # when falsy (`upgrade: false` is "is not None"), matching
      # AnsibleModule's own check_mutually_exclusive. Previously this
      # engine let name+upgrade through to its own later
      # "unable to install additional packages when upgrading all
      # installed packages" guard - Ansible's mutually-exclusive
      # check fires first and that wording is only reachable via
      # state=latest + name "*" + extra packages (kept there).
      mutex_group = [] of String
      mutex_group << "deb" if @params["deb"]?
      mutex_group << "package" if name_or_pkg_param?
      mutex_group << "upgrade" if @params.has_key?("upgrade")
      if mutex_group.size > 1
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "parameters are mutually exclusive: deb|package|upgrade"
        )
      end

      # state choices (apt.py's own choice list, checked at setup before
      # main() - live-verified wording: "value of state must be one of:
      # absent, build-dep, fixed, latest, present, got: <value>").
      # Previously the rejection came from this plugin's own fall-through
      # ("Invalid state: ... Must be present, absent, or latest") and
      # only recognized a third of Ansible's choice list.
      state = @params["state"]? || "present"
      unless APT_STATES.includes?(state)
        return choices_error("state", APT_STATES, state)
      end

      # Bool-typed params: a non-boolean value fails the module at setup
      # with real check_type_bool's wording, via the shared BasePlugin
      # validator (see its own block comment for the full story; message
      # live-verified against ansible-core 2.19.11: "argument
      # 'install_recommends' is of type str and we were unable to convert
      # to bool: The value 'sometimes' is not a valid boolean. Valid
      # booleans include: ..."). Previously this plugin silently coerced
      # anything non-"true" to false and happily proceeded where
      # Ansible never gets past argument validation.
      validate_bool_params!

      # Ansible's apt module on a non-Debian-family host: it first
      # auto-installs its python3-apt dependency ("Updating cache and
      # auto-installing missing dependency: python3-apt" warning) via
      # AnsibleModule.run_command, which fails ENOENT with exactly
      # {"changed": false, "cmd": "update", "msg": "Error executing
      # command.", "rc": 2} - observed live on Rocky 9.6 with Oefenweb.dns
      # (round 196). Without this guard this engine's dpkg-query-based
      # absent path quietly reported "Package ... not installed" rc=0.
      unless File.exists?("/usr/bin/apt-get") || File.exists?("/usr/local/bin/apt-get")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Error executing command.",
          cmd: "update",
          rc: 2
        )
      end

      # Ansible's apt module auto-installs the python3-apt bindings
      # (with an `apt-get update` prefetch) at module start when missing
      # and then respawns - see AptLockRetry#apt_auto_install_python_apt
      # for why this has to be a real, persistent host mutation rather
      # than a per-invocation emulation: without it a host that starts
      # without the bindings stays on the "absent → changed=false"
      # cache-refresh path forever instead of moving to the mtime-diff
      # path after the first apt task (found via geerlingguy.kubernetes,
      # rounds 65166/65311). Check mode skips this - Ansible fails
      # fast in check mode instead (refusal mirrored inside the
      # update-cache block below, where it has always lived here).
      unless @check_mode
        explicitly_no_cache = @params["update_cache"]? ? !true?(@params["update_cache"]?) : false
        if failure = apt_auto_install_python_apt(explicitly_no_cache, ->remote_exec(String))
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to auto-install python3-apt: #{failure[:stderr]}"
          )
        end
      end

      # Get state (default: present)
      state = @params["state"]? || "present"
      if @params["deb"]? && state != "present"
        @omit_cache_updated = true
        return PluginResult.new(changed: false, failed: true, msg: "deb only supports state=present")
      end
      update_cache = true?(@params["update_cache"]?)
      cache_valid_time = @params["cache_valid_time"]?.try(&.to_i) || 0
      # Ansible treats a bare `cache_valid_time: N` with NO name/
      # upgrade/deb as a cache-refresh-only invocation (apt.py's own
      # `if p['cache_valid_time']:` branch runs the update pass and
      # early-exits ok) - a common "keep the apt cache fresh" idiom
      # (riemers.gitlab-runner's "(Debian) Refresh package cache" task).
      # This plugin only recognized an explicit update_cache: true, so
      # the name-less form failed outright with "Missing required
      # parameter: name". cache_valid_time=0 is Python-falsy = absent,
      # matching apt.py exactly.
      has_cache_valid_time = cache_valid_time > 0
      # Ansible's apt module exposes `lock_timeout` (default 60s) for
      # install/remove/upgrade operations and `update_cache_retries`
      # (default 5) + `update_cache_retry_max_delay` (default 12s) for
      # `apt-get update`. Found missing in round 153 (2026-08-20) when a
      # fresh Atlantic.net Ubuntu host's unattended-upgr held the dpkg
      # lock during `apt:`; Ansible's apt module waited up to 60s
      # for the lock and succeeded, krikri-playbook failed fast. See
      # `KNOWN_MISSING.md` / round 153 results for the full trace.
      # Wire the same parameter names here so user playbooks that
      # override them on either engine work identically.
      lock_timeout = @params["lock_timeout"]?.try(&.to_i) || 60
      update_cache_retries = @params["update_cache_retries"]?.try(&.to_i) || 5
      update_cache_retry_max_delay = @params["update_cache_retry_max_delay"]?.try(&.to_i) || 12

      # Proactive param-coverage pass: the remaining real-Ansible apt
      # module options (apt.py's argument_spec), mapped onto this
      # plugin's apt-get invocations the same way apt.py maps them onto
      # its own. Flag-for-flag: only_upgrade/--only-upgrade, force/
      # --force-yes, fail_on_autoremove/--no-remove,
      # allow_unauthenticated/--allow-unauthenticated, allow_downgrade/
      # --allow-downgrades, allow_change_held_packages/
      # --allow-change-held-packages, purge/--purge, default_release/-t,
      # install_recommends/-o APT::Install-Recommends=..., and
      # dpkg_options (comma-separated, each expanded to its own -o
      # Dpkg::Options::=--<opt> exactly like apt.py's
      # expand_dpkg_options). `force_apt_get` and
      # `auto_install_module_deps` are documented no-ops here (see the
      # class comment above).
      @dpkg_options = @params["dpkg_options"]? || "force-confdef,force-confold"
      @policy_rc_d = @params["policy_rc_d"]?.try(&.to_i?)
      @policy_rc_d_path = @params["_policy_rc_d_path"]? || "/usr/sbin/policy-rc.d"
      @purge = true?(@params["purge"]?)
      @force = true?(@params["force"]?)
      @fail_on_autoremove = true?(@params["fail_on_autoremove"]?)
      @only_upgrade = true?(@params["only_upgrade"]?)
      @allow_unauthenticated = true?(@params["allow_unauthenticated"]?)
      @allow_downgrade = true?(@params["allow_downgrade"]?)
      @allow_change_held_packages = true?(@params["allow_change_held_packages"]?)
      @default_release = @params["default_release"]?
      # python-apt opens the cache with APT::Default-Release set and raises
      # SystemError("E:The value ... is invalid ...") for an unknown release -
      # an unhandled module exception, surfaced as "Task failed: Module failed:"
      # in the fatal msg and the [ERROR] block (live-verified vs 2.19.11).
      if release = @default_release.presence
        probe = remote_exec("apt-get -o APT::Default-Release=#{Process.quote(release)} check 2>&1")
        if line = probe[:stdout].lines.find(&.includes?("is invalid for APT::Default-Release"))
          detail = line.strip.sub(/\AE: /, "E:")
          return PluginResult.new(changed: false, failed: true, msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
        end
      end
      if ir = @params["install_recommends"]?
        @install_recommends = true?(ir)
      end

      changed = false
      messages = [] of String

      # Ansible's own apt.py only lets a cache refresh contribute to
      # the task's overall `changed:` when update_cache: is the ONLY
      # thing requested (`if not p['package'] and not p['upgrade'] and
      # not p['deb']: module.exit_json(changed=updated_cache, ...)`) -
      # once name:/upgrade:/deb: is ALSO given, the early-exit never
      # happens and `changed` is decided entirely by that package/
      # upgrade/deb operation's own result, regardless of whether the
      # cache itself needed refreshing. Previously this plugin OR'd the
      # cache-refresh's own `changed = true` into the same shared local
      # unconditionally, so `apt: {update_cache: true, upgrade: dist}`
      # always reported `changed: true` merely from refreshing the
      # package lists, even when the subsequent dist-upgrade genuinely
      # found "0 upgraded, 0 newly installed, 0 to remove" and
      # Ansible correctly reported `ok`. Found benchmarking robertdebock.
      # update's own "Update all software (apt)" task.
      # `name_or_pkg_param?` alone only tests whether the KEY is present -
      # `name: '{{ php_packages_extra }}'` with the var defaulting to `[]`
      # renders as the literal string "[]", a present-but-empty name: that
      # is exactly as "sole operation" as no name: at all (0ta2.php_role's
      # "Install extra package.", round 84000: Ansible folded the
      # cache refresh's own changed: in here; this engine saw a present
      # name: param and never did, losing the changed: entirely).
      no_effective_packages = (raw_name = name_or_pkg_param?).nil? || parse_package_names(raw_name).empty?
      # upgrade: "no" is the argspec default spelled out - apt.py maps it to
      # None (`if p['upgrade'] == 'no': p['upgrade'] = None`), i.e. no upgrade
      upgrade_requested = (raw_upgrade = @params["upgrade"]?) && raw_upgrade != "no"
      cache_update_is_sole_operation = no_effective_packages && !upgrade_requested && !@params["deb"]?

      # Real apt.py reads the lists-dir mtime unconditionally at the top
      # of its cache pass (get_updated_cache_time()) - not just when an
      # update is due - so an install with no cache flags at all still
      # carries the current mtime as cache_update_time.
      @cache_update_time = cache_mtime

      # Handle cache update
      if update_cache || has_cache_valid_time
        # Ansible's apt module cannot run at all in check mode when
        # it can't see the python3-apt bindings (its auto-install fallback
        # is a real mutation, so check mode fails fast instead) - mirror
        # that refusal. On hosts WITH python3-apt nothing changes here.
        if @check_mode && !python_apt_present?
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: AptLockRetry::CHECK_MODE_NO_PYTHON_APT_MSG
          )
        end
        if should_update_cache?(cache_valid_time)
          if @check_mode
            messages << "Would update apt cache"
            changed = true if cache_update_is_sole_operation
            # Real apt.py: `if module.check_mode or updated_cache_time !=
            # post_cache_update_time: updated_cache = True` - a check-mode
            # cache pass claims updated_cache/cache_updated unconditionally
            # once the update was actually due.
            @cache_updated = true
          elsif !python_apt_present?
            # Normal flow never reaches this branch - the module-start
            # auto-install above either puts the bindings in place or
            # fails the task, matching Ansible's respawn. It is the
            # fallback for a host where the install "succeeded" but the
            # bindings still won't import. On a host WITHOUT python3-apt,
            # Ansible auto-installs it
            # before its measurement window even opens - and that auto-install
            # step runs a full `apt-get update` first (apt.py's "Updating cache
            # and auto-installing missing dependency" path), then RESPAWNS the
            # module, so the before/after mtime pair is read entirely AFTER
            # that prefetch. A cache-refresh-only invocation therefore reports
            # `ok` on such hosts even when the prefetch genuinely fetched new
            # lists (verified live: deleting a lists file + aging the dir
            # mtime, Ansible fetched - /var/lib/apt/lists's mtime moved -
            # and still reported changed=False while python3-apt was absent,
            # and changed=True once it was present). Since this plugin shells
            # out to the CLI and never installs python3-apt, emulate
            # Ansible's observable behavior: run the update for its side
            # effects, but keep changed=false for the sole-operation case
            # regardless of mtime movement.
            pre_update_mtime = cache_mtime
            update_result = apt_get_update_with_retry("apt-get update", update_cache_retries, update_cache_retry_max_delay, ->remote_exec(String))
            if failure = settle_update_cache_failure(update_result, update_cache_retries, update_cache_retry_max_delay)
              return failure
            end
            messages << "APT cache updated"
            @cache_updated = cache_mtime != pre_update_mtime
            @cache_update_time = cache_mtime
          else
            # Ansible's apt module wraps the cache update with
            # `update_cache_retries` + `update_cache_retry_max_delay`
            # (defaults 5 and 12): dpkg-lock contention is retried by
            # apt_get_update_with_retry above, and a fetch failure -
            # python-apt's bare FetchFailedException, which the CLI's
            # exit-0-but-W:-lines output maps to - goes through
            # settle_update_cache_failure's own apt.py-shaped retry loop
            # (warnings included) instead of failing fast.
            #
            # Ansible's own get_updated_cache_time() stats the same
            # update-success-stamp/lists-dir mtime BEFORE and AFTER
            # running the cache update, and only reports changed=true if
            # that mtime actually moved - with python3-apt present, both
            # python-apt's Cache().update() and the CLI `apt-get update`
            # leave the on-disk lists untouched when the upstream repo
            # content hasn't changed (conditional/hashsum-checked fetch;
            # verified live: an all-Hit `apt-get update` run does NOT
            # bump /var/lib/apt/lists's mtime), so a rerun against an
            # already-fresh mirror is a genuine no-op. This plugin
            # previously set changed=true unconditionally whenever it ran
            # the update as the sole operation, regardless of whether
            # anything on disk actually moved - found benchmarking
            # claranet.users's own "Update APT cache" task on a
            # freshly-imaged host (image already had a current cache from
            # build): py reported `ok`, cr `changed`.
            pre_update_mtime = cache_mtime
            update_result = apt_get_update_with_retry("apt-get update", update_cache_retries, update_cache_retry_max_delay, ->remote_exec(String))
            if failure = settle_update_cache_failure(update_result, update_cache_retries, update_cache_retry_max_delay)
              return failure
            end
            messages << "APT cache updated"
            post_update_mtime = cache_mtime
            changed = true if cache_update_is_sole_operation && post_update_mtime != pre_update_mtime
            @cache_updated = post_update_mtime != pre_update_mtime
            @cache_update_time = post_update_mtime
          end
        end
      end

      # Get package name(s) - can be optional if just updating cache, or
      # running autoremove/autoclean/clean (Ansible's apt module
      # supports all four with no `name:` at all - konstruktoid-hardening's
      # own "Run apt-get autoremove"/"Run apt-get clean" handlers do
      # exactly `autoremove: true` and `autoclean: true, clean: true`
      # with no name).
      name_param = name_or_pkg_param?
      autoremove = true?(@params["autoremove"]?)
      autoclean = true?(@params["autoclean"]?)
      clean = true?(@params["clean"]?)
      upgrade = @params["upgrade"]?
      upgrade = nil if upgrade == "no"

      # Ansible's apt module NEVER reaches its own cleanup()
      # (autoremove/autoclean) when `upgrade:` is set: upgrade() always
      # exits the module (exit_json/fail_json) before the `if not
      # packages: if autoclean/autoremove: cleanup(...)` tail runs, and
      # the autoremove intent is folded INTO the upgrade command itself
      # (`dist-upgrade --auto-remove` / `upgrade --with-new-pkgs
      # --auto-remove`). Previously this plugin still ran the standalone
      # `apt-get -y autoremove` - and ran it BEFORE the upgrade: on a
      # host whose cold dist-upgrade obsoletes auto-installed packages
      # (canonical case: a new kernel ABI makes the previous kernel
      # autoremovable), the cold run's autoremove had nothing to remove
      # yet, the upgrade then created the leftovers, and the WARM run's
      # standalone autoremove removed them - so warm reruns reported
      # `changed: true` forever where Ansible reported `ok`
      # (entanet_devops.common / entanet_devops.upgrade, rounds 73358+).
      # Ansible's apt module only ever reaches cleanup() for
      # autoremove/autoclean when NO packages were requested (`if not
      # packages: if autoclean: cleanup(...); if autoremove:
      # cleanup(...)` in main()) - with a package list present,
      # state=absent folds autoremove into the remove command itself
      # (`--auto-remove`, remove()'s own autoremove flag) and state=
      # present never cleans, in both cases exiting before the cleanup
      # tail. Previously this plugin ran the standalone cleanups
      # alongside a package list too: `purge: true` + `autoclean: true`
      # produced `apt-get -y ... --purge autoclean`, which modern
      # apt-get rejects outright ("Command line option --purge is not
      # understood in combination with the other options") -
      # andrelohmann.docker's "Apt | Remove distribution packages" task
      # (purge+autoclean+autoremove+name, round 1300020) failed on every
      # run where Ansible just purged the packages.
      # `clean` stays unconditional: real aptclean() runs before the
      # package dispatch with or without packages (its early-exit only
      # short-circuits the RESULT, not the `apt-get clean` run).
      if (autoremove || autoclean || clean) && !upgrade
        # Ansible's cleanup() builds `apt-get -y <dpkg_options>
        # <purge> <force_yes> <operation>` - the purge/force flags and
        # the dpkg options apply to autoremove/autoclean too (`purge:
        # true` + `autoremove: true` is its own documented idiom: "Remove
        # dependencies that are no longer required and purge their
        # configuration files"). `apt-get clean` is the exception:
        # Ansible's aptclean() runs the bare command with no options at
        # all, so it stays bare here.
        # Ansible's main() builds its `dpkg_options` ONCE - the
        # expanded list PLUS the lock-timeout override - and passes that
        # same value to cleanup(), install(), remove() and upgrade()
        # alike, so the lock timeout rides along on the cleanup command
        # too (live-verified against ansible-core 2.19.11: `apt-get -y
        # -o Dpkg::Options::=--force-confdef -o
        # Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=60
        # --purge --force-yes autoremove`).
        cleanup_flags = [real_dpkg_options(lock_timeout), (@purge ? "--purge" : nil), (@force ? "--force-yes" : nil)].compact.join(" ")
        {
          {autoremove && no_effective_packages, "#{apt_get_bin} -y#{cleanup_flags.empty? ? "" : " " + cleanup_flags} autoremove", "packages removed"},
          {autoclean && no_effective_packages, "#{apt_get_bin} -y#{cleanup_flags.empty? ? "" : " " + cleanup_flags} autoclean", "autocleaned"},
          {clean, "apt-get clean", "cache cleaned"},
        }.each do |(enabled, cmd, label)|
          next unless enabled

          if @check_mode
            messages << "Would run: #{cmd}"
            changed = true
            next
          end

          # `autoremove`/`autoclean` are apt-get operations that contend
          # for the dpkg lock - wrap with lock_timeout retry, matching
          # Ansible's `apt` module behavior (see execute's param
          # parsing comment for the full trace). Ansible wraps its
          # cleanup() command in its PolicyRcD context manager like every
          # other package operation - mirrored below.
          result = with_policy_rc_d { apt_with_lock_retry(cmd, lock_timeout, ->remote_exec(String)) }
          if result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true, msg: "#{cmd} failed: #{result[:stderr]}")
          end

          # Ansible's apt module checks for a specific marker
          # string in apt-get's own stdout, per operation
          # (CLEAN_OP_CHANGED_STR in apt.py) - NOT empty-vs-non-empty
          # output. `autoclean`/`autoremove` (and plain `apt-get
          # update`) print informational "Reading package lists..."
          # boilerplate to stdout unconditionally, whether or not
          # anything was actually removed, so the previous "non-empty
          # stdout means changed" heuristic always reported changed:
          # true for autoclean specifically. `clean:` (Ansible's
          # own `aptclean()`) reports changed: true UNCONDITIONALLY
          # when called with no package/upgrade/deb - not based on
          # output at all.
          did_something = case cmd
                          when .includes?("autoremove")
                            result[:stdout].includes?("The following packages will be REMOVED")
                          when .includes?("autoclean")
                            result[:stdout].includes?("Del ")
                          else
                            true
                          end

          if did_something
            changed = true
            messages << label
          end
        end
      end

      # `upgrade: safe|yes|dist|full` with no `name:` -
      # Ansible's apt module maps safe/yes to a plain
      # `apt-get upgrade --with-new-pkgs` and dist/full to
      # `apt-get dist-upgrade`, with `--auto-remove` appended when
      # `autoremove: yes` is also given (see the cleanup block above).
      # The task registers this result and computes its own
      # `changed_when` from `.stdout` (`'0 upgraded, 0 newly installed,
      # 0 to remove' not in apt_upgrade_response.stdout`), so the raw
      # command output has to actually reach the registered var's
      # `stdout` field, not just inform `changed`/`msg` here - passed
      # through via the `stdout:` kwarg the same way the package-install
      # path below already does.
      upgrade_stdout = ""
      upgrade_stderr = ""
      upgrade_zero_effect = false
      if upgrade
        dist = upgrade == "dist" || upgrade == "full"
        # Real upgrade()'s EXACT command format: "%s -y %s %s %s %s %s %s
        # %s" over (apt_cmd_path, dpkg_options, force_yes,
        # fail_on_autoremove, allow_unauthenticated, allow_downgrade,
        # check_arg, upgrade_command) - the empty flag fields KEEP their
        # separators, and upgrade_command itself carries a trailing space
        # whenever autoremove is unset ("dist-upgrade " / "upgrade
        # --with-new-pkgs "). That exact string is what Ansible's failure
        # msg quotes ("'%s %s' failed: %s" over APT_GET_CMD and
        # upgrade_command), so the spacing is load-bearing for wording
        # parity, not cosmetics. Like install(), the command RUNS in
        # check mode too - with --simulate - and its output is the
        # registered stdout (round-99500x apt_check_upgrade capture).
        subcmd = dist ? "dist-upgrade" : "upgrade --with-new-pkgs"
        upgrade_command = "#{subcmd} #{autoremove ? "--auto-remove" : ""}"
        cmd = "#{apt_get_bin} -y #{real_dpkg_options(lock_timeout)} #{@force ? "--force-yes" : ""} #{@fail_on_autoremove ? "--no-remove" : ""} #{@allow_unauthenticated ? "--allow-unauthenticated" : ""} #{@allow_downgrade ? "--allow-downgrades" : ""} #{@check_mode ? "--simulate" : ""} #{upgrade_command}"
        cmd += " -t #{naive_single_quote(@default_release.not_nil!)}" if @default_release

        # `apt-get upgrade`/`dist-upgrade` contend for the dpkg lock -
        # wrap with lock_timeout retry (same rationale as the
        # autoremove/autoclean wrap above), inside the same
        # policy-rc.d lifecycle Ansible's upgrade() uses.
        result = with_policy_rc_d { apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive #{cmd}", lock_timeout, ->remote_exec(String)) }
        if result[:exit_code] != 0
          # Real upgrade() failure: fail_json(msg="'%s %s' failed: %s"
          # % (apt_cmd, upgrade_command, err), stdout=out, rc=rc) - NO
          # stderr key at all (round-99500x capture).
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "'#{apt_get_bin} #{upgrade_command}' failed: #{result[:stderr]}",
            stdout: result[:stdout],
            rc: result[:exit_code],
            key_order: ["stdout", "rc", "failed", "msg"]
          )
        end

        upgrade_stdout = result[:stdout]
        upgrade_stderr = result[:stderr]
        # Ansible screenscrapes APT_GET_ZERO - "\n0 upgraded, 0
        # newly installed, 0 to remove" with a LEADING newline. The
        # previous check here omitted the newline, so any summary
        # whose upgraded-count ends in 0 ("10 upgraded, 0 newly
        # installed, 0 to remove ...") matched the zero-string at
        # offset 1 and falsely reported a no-op upgrade.
        upgrade_zero_effect = result[:stdout].includes?("\n0 upgraded, 0 newly installed, 0 to remove")
        changed = !upgrade_zero_effect
        messages << result[:stdout]
      end

      # `deb:` - install a local .deb file (or a URL, downloaded first),
      # distinct from `name:` (a repository package name/version).
      # Ansible's apt module derives the package's own name+version from
      # the .deb's control metadata (`dpkg-deb -f`) to decide idempotency,
      # then mirrors install_deb(): the .deb's own Depends/Pre-Depends are
      # resolved FIRST (missing ones installed through the normal apt-get
      # install() path) and only then does `dpkg <options> -i` run - a
      # bare dpkg -i cannot resolve dependencies and dies with "dependency
      # problems prevent configuration" (round-1200xxx: appsilon.r_language,
      # JonasPammer/kso512.checkmk_server, kso512.checkmk_server and
      # Oefenweb.rstudio_server all failed exactly that way while real
      # ansible-playbook installed the missing deps and succeeded).
      # Entirely
      # unimplemented before - found via robertdebock.zabbix_repository's
      # own "Install (apt) repository" task (`apt: {deb: "{{
      # zabbix_repository_package }}"}`, round 18) - fell straight through
      # to the "no name: given" branch below and failed outright even
      # though a real install target (`deb:`) was given.
      deb_param = @params["deb"]?
      if deb_param
        # install_deb exits through its own fail_json/exit_json calls
        # before main() ever assigns cache_updated/cache_update_time, so
        # a deb: result carries neither key on ANY exit (the round-
        # 1100002 kop_apt_fail apt_fail_deb capture: a failed deb: is
        # [failed, msg, changed, exception], while the engine-wide
        # backfill below was inserting cache_updated between msg and
        # changed). Suppress the backfill for the whole deb path.
        @omit_cache_updated = true
        return handle_deb(deb_param, messages, changed, lock_timeout)
      end

      # If no package name provided, just return cache update result
      unless name_param
        if (update_cache || has_cache_valid_time) && !upgrade_requested
          # Real apt.py's cache-only early exit (its own "If there is
          # nothing else to do exit" branch, INSIDE the update_cache/
          # cache_valid_time block): exit_json(changed=updated_cache,
          # cache_updated=updated_cache, cache_update_time=
          # updated_cache_time) - no msg, no stdout (round-992002
          # ufw_helper_install capture: [changed, cache_updated,
          # cache_update_time, failed]).
          return PluginResult.new(
            changed: changed,
            failed: false,
            cache_update_time: @cache_update_time,
            key_order: ["changed", "cache_updated", "cache_update_time"]
          )
        elsif update_cache || has_cache_valid_time || autoremove || autoclean || clean || upgrade
          msg = messages.empty? ? "Cache up to date" : messages.join(", ")
          if upgrade_requested
            # Real upgrade()'s two success exits (round-99500x captures
            # apt_check_upgrade / apt_check_upgrade_zero): the
            # APT_GET_ZERO no-effect exit is exit_json(changed=False,
            # msg=out, stdout=out, stderr=err) with NO diff key at all;
            # anything else is exit_json(changed=True, msg=out,
            # stdout=out, stderr=err, diff=diff).
            exit_keys = upgrade_zero_effect ? ["changed", "msg", "stdout", "stderr", "stdout_lines", "stderr_lines"] : ["changed", "msg", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"]
            return PluginResult.new(
              changed: changed,
              failed: false,
              msg: msg,
              stdout: upgrade_stdout,
              stderr: upgrade_stderr,
              diff: upgrade_zero_effect ? nil : apt_install_diff(upgrade_stdout),
              key_order: exit_keys
            )
          end
          return PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: upgrade_stdout,
            key_order: ["changed", "cache_updated", "cache_update_time"]
          )
        else
          # Bookworm's apt.py (the harness reference) has NO
          # required_one_of - `apt: {state: present}` with no name, no
          # upgrade, no deb and no cache refresh just exits ok with
          # changed: false and no msg (live-verified via the
          # podman-diff apt_edge_cases A10/A14 cases). The previous
          # "Missing required parameter: name (unless using
          # update_cache)" failure was this engine's own invention.
          # Real apt.py: exit_json(changed=False) - the bare
          # no-name/no-operations ok. That bare ok comes from install()'s
          # empty-spec retvals, so main() still assigns
          # cache_updated/cache_update_time onto it for the
          # install-family states ('latest', 'present', 'build-dep',
          # 'fixed') - only state=absent's remove() exits inside its own
          # function and stays bare (round-99500x apt_absent_noop;
          # round 1100002's apt_fixed capture pins the cache-keyed shape:
          # [changed, cache_updated, cache_update_time, failed]).
          if state == "absent"
            @omit_cache_updated = true
            return PluginResult.new(
              changed: false,
              failed: false,
              key_order: ["changed"]
            )
          end
          return PluginResult.new(
            changed: false,
            failed: false,
            cache_update_time: @cache_update_time,
            key_order: ["changed", "cache_updated", "cache_update_time"]
          )
        end
      end

      # Parse package names - handle both single string and comma-separated list
      packages = parse_package_names(name_param)

      # A `name:` KEY present but templating down to nothing - `name:
      # '{{ php_packages_extra }}'` with the var defaulting to `[]`
      # renders as the literal string "[]", so `name_param` itself is
      # truthy and the "no name: at all" branch above never fires, even
      # though there is genuinely nothing to install/remove.
      # Ansible's apt module folds a cache update's own changed: into
      # this case too (an empty package list is exactly the same as no
      # name: given at all to its own install()/remove() no-ops) -
      # 0ta2.php_role's "Install extra package." (apt: {name: '{{
      # php_packages_extra }}', update_cache: yes}, round 84000) reported
      # changed: true from the real apt-get update alone; this engine
      # instead fell through into the packages-present install path with
      # an empty list and lost that changed: entirely.
      if packages.empty?
        if (update_cache || has_cache_valid_time) && !upgrade_requested
          # Same cache-only early exit as the no-name case above (real
          # apt.py's `not p['package']` reads an empty list the same way).
          return PluginResult.new(
            changed: changed,
            failed: false,
            cache_update_time: @cache_update_time,
            key_order: ["changed", "cache_updated", "cache_update_time"]
          )
        elsif update_cache || has_cache_valid_time || autoremove || autoclean || clean || upgrade
          msg = messages.empty? ? "Cache up to date" : messages.join(", ")
          if upgrade_requested
            # Real upgrade()'s two success exits (round-99500x captures
            # apt_check_upgrade / apt_check_upgrade_zero): the
            # APT_GET_ZERO no-effect exit is exit_json(changed=False,
            # msg=out, stdout=out, stderr=err) with NO diff key at all;
            # anything else is exit_json(changed=True, msg=out,
            # stdout=out, stderr=err, diff=diff).
            exit_keys = upgrade_zero_effect ? ["changed", "msg", "stdout", "stderr", "stdout_lines", "stderr_lines"] : ["changed", "msg", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"]
            return PluginResult.new(
              changed: changed,
              failed: false,
              msg: msg,
              stdout: upgrade_stdout,
              stderr: upgrade_stderr,
              diff: upgrade_zero_effect ? nil : apt_install_diff(upgrade_stdout),
              key_order: exit_keys
            )
          end
          return PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: upgrade_stdout,
            key_order: ["changed", "cache_updated", "cache_update_time"]
          )
        else
          # Same no-name-ok behavior for the empty-name-list case (see
          # the branch above) - Ansible's install()/remove() no-ops
          # exit_json with nothing to say, not a "Nothing to do" msg.
          # Real apt.py: exit_json(changed=False) - the bare
          # no-name/no-operations ok, with the same state split as the
          # branch above (install-family states gain the cache keys from
          # main()'s retvals assignment, state=absent stays bare).
          if state == "absent"
            @omit_cache_updated = true
            return PluginResult.new(
              changed: false,
              failed: false,
              key_order: ["changed"]
            )
          end
          return PluginResult.new(
            changed: false,
            failed: false,
            cache_update_time: @cache_update_time,
            key_order: ["changed", "cache_updated", "cache_update_time"]
          )
        end
      end

      # Process each package based on state. Ansible's own apt
      # module only ever folds a cache update into the overall changed:
      # when no package/upgrade/deb was requested at all (its own
      # early-return branch, matched above) - once packages are given,
      # changed: reflects package-level install/remove/upgrade activity
      # only, never whether apt-get update itself refreshed anything
      # (verified against its actual source: `m.exit_json(changed=changed,
      # ...)` at the end of the general install path is computed from
      # scratch there, not seeded from the cache-update flag). Found via
      # a real playbook run over real SSH where update_cache: true
      # alongside an already-fully-installed package list still reported
      # changed: true on every single rerun.
      case state
      when "present"
        handle_install(packages, messages, false, lock_timeout)
      when "absent"
        handle_remove(packages, lock_timeout)
      when "latest"
        # `name: "*"` is Ansible's apt.py spelling for "upgrade
        # everything installed" (its own `all_installed = '*' in
        # unfiltered_packages` check) - a DISTINCT code path from a
        # per-package install, not a package literally named "*". See
        # `handle_wildcard_latest` for why treating it as an ordinary
        # package name (the previous behavior here) is a real bug, not
        # just a style choice.
        if packages.includes?("*")
          if packages.size > 1
            # apt.py's own fail_json message verbatim - Ansible
            # refuses to mix "*" with real package names rather than
            # guessing which one the caller meant.
            PluginResult.new(
              changed: false,
              failed: true,
              msg: "unable to install additional packages when upgrading all installed packages"
            )
          else
            handle_wildcard_latest(messages, autoremove, lock_timeout)
          end
        else
          handle_latest(packages, messages, false, lock_timeout)
        end
      when "build-dep"
        handle_install(packages, messages, false, lock_timeout, build_dep: true)
      when "fixed"
        handle_install(packages, messages, false, lock_timeout, fixed_state: true)
      else
        # Unreachable in practice: state was already validated against
        # real apt.py's choice list at module-setup above.
        choices_error("state", APT_STATES, state)
      end
    end

    # `package:`/`pkg:` are documented aliases of `name:` for
    # Ansible's apt module (`aliases: [package, pkg]`).
    private def name_or_pkg_param? : String?
      @params["name"]? || @params["package"]? || @params["pkg"]?
    end

    # Parse package names from parameter (handles comma-separated, single,
    # or a JSON-array-shaped string).
    private def parse_package_names(name_param : String) : Array(String)
      # `name: "{{ packages_debian }}"` (konstruktoid-hardening's own
      # "Debian family package installation" task) templates a *list*
      # var through a plain `{{ }}` substitution - a whole-span
      # container arg arrives as the double-quoted JSON
      # VariableLookup#format_value serialized it to
      # (`["acct","apparmor-profiles",...]`, see
      # substitute_task_params's whole-single-span comment). Splitting
      # that on "," (the plain comma-separated case below) left the
      # brackets/quotes stuck to the first and last entries ("[acct",
      # "wamerican]"), which apt then rejected outright as invalid
      # package names. Detected here and parsed as real JSON instead.
      #
      # ONLY valid JSON, though - never a Python-repr repair pass. A
      # value that merely LOOKS like a container (a literal
      # `name: "['pkg1']"` string, or a `{% if %}...{% else %}
      # ['pkg1']{% endif %}` block's rendered output) is a plain STRING
      # in ansible-core - native typing requires the template's
      # whole AST to be one output node wrapping one expression, so
      # block-tag output is never re-parsed (live-verified vs
      # ansible-playbook 2.19.11: `apt: name: "['probe-pkg-one',
      # 'probe-pkg-two']"` fails with "No package(s) matching
      # '['probe-pkg-one'' available" - Ansible comma-splits the
      # repr-looking string into garbage names and fails looking them
      # up, exactly what the plain comma-split below now produces,
      # instead of the old single-quote repair that decomposed it into
      # a real list and installed both packages). Found live
      # benchmarking prometheus.prometheus.blackbox_exporter.
      trimmed = name_param.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        return parsed if parsed
      end

      # Split by comma and clean up whitespace. Empty segments are KEPT:
      # Ansible treats each comma-split piece as a real package
      # name and fails with "No package matching '' is available" for
      # an empty one (live-verified in check mode for `name: ""`,
      # leading `",probe-pkg-one"`, middle `"bash,,bash"` - with bash
      # actually installed - and trailing `"bash,"`), so the old
      # `.reject(&.empty?)` silently turned `name: ""` (inverse_inc.
      # gitlab_buildpkg_tools's `name: "{{ lookup('env',
      # 'DEB_PACKAGES_NAME') }}"` with the env var unset - the lookup
      # correctly yields "") into "no packages, cache update only" and
      # reported ok where Ansible fails the task.
      name_param.split(",").map(&.strip)
    end

    # Ansible's apt module supports real apt's own `name=version`
    # pinning syntax (e.g. `rabbitmq-server={{ rabbitmq_version }}-1`,
    # geerlingguy.rabbitmq's own install task) - `dpkg -l` doesn't
    # understand that syntax at all (it takes a bare package-name glob,
    # not `name=version`), so passing the raw pinned string straight to
    # `dpkg -l` in the is-it-already-installed check always failed to
    # match, reporting "changed" on literally every single run even
    # once the exact pinned version was already installed.
    private def split_name_version(pkg : String) : {String, String?}
      idx = pkg.index('=')
      idx ? {pkg[0...idx], pkg[(idx + 1)..]} : {pkg, nil}
    end

    # Real install()'s spec construction for one package: a pinned spec
    # keeps its pin, a plain name gets the resolved candidate version
    # pinned on ("tree" -> "tree=2.0.2-1"), and a purely virtual name
    # (Candidate: (none)) stays bare - Ansible's version_installable=True
    # path. Wildcard pins keep their raw pattern (real resolves them
    # through package_best_match's fnmatch; the raw pin is the same
    # string for the exact-pin common case).
    private def install_spec(pkg : String, candidates : Hash(String, String?)) : String
      base_name, pinned_version = split_name_version(pkg)
      version = pinned_version || candidates[base_name]?
      version ? "#{base_name}=#{version}" : base_name
    end

    # Real install()'s per-spec candidate probe: does this package name
    # exist in the apt cache at all, and what candidate version does it
    # resolve to? Ansible does the lookup in-process (python-apt's
    # cache[pkgname] + get_providing_packages for virtual names) with NO
    # apt-get invocation at all, so `apt-cache policy` is the CLI
    # stand-in. The stanza's Candidate: line is the tell: an unknown
    # name prints no stanza at all (resolvable: false), a known real
    # package carries "Candidate: <version>", and a purely virtual one
    # "Candidate: (none)" (resolvable: true, version nil - the same
    # let-apt-get-sort-it-out treatment real gives virtual names).
    private def apt_candidate(name : String) : {Bool, String?}
      probe = remote_exec("apt-cache policy #{shell_single_quote(name)} 2>/dev/null")
      return {false, nil} unless probe[:stdout].includes?("Candidate:")
      probe[:stdout].each_line do |line|
        stripped = line.strip
        if stripped.starts_with?("Candidate:")
          version = stripped.lchop("Candidate:").strip
          return {true, version.empty? || version == "(none)" ? nil : version}
        end
      end
      {true, nil}
    end

    # Real install()'s pinned-version probe: version_installable in
    # package_status() is "does this exact version exist in the apt
    # cache" - apt-cache policy's own version table is the CLI-equivalent
    # source. A wildcard pin (name=16.*) is fnmatched against every
    # version in that table, like real's fnmatch over the cache's
    # versions (a wildcard that matches nothing fails with the same
    # "no available installation candidate" msg); it used to be rejected
    # outright, failing every `nodejs=16.*`-style pin on a host where the
    # candidate existed.
    private def pinned_version_installable?(name : String, version : String) : Bool
      probe = remote_exec("apt-cache policy #{shell_single_quote(name)}")
      return false unless probe[:exit_code] == 0
      probe[:stdout].split('\n').any? do |line|
        tokens = line.strip.split
        tokens.delete("***")
        next false unless first = tokens.first?
        version_pin_matches?(version, first)
      end
    end

    # fnmatch.fnmatch semantics for an apt version pin: `*`, `?` and
    # `[...]` classes; a pin without a wildcard is an exact comparison.
    private def version_pin_matches?(pin : String, candidate : String) : Bool
      return pin == candidate unless pin.matches?(/[*?\[]/)
      regex = String.build do |io|
        io << "\\A"
        pin.each_char do |char|
          case char
          when '*' then io << ".*"
          when '?' then io << '.'
          when '[', ']' then io << char
          else          io << Regex.escape(char.to_s)
          end
        end
        io << "\\z"
      end
      Regex.new(regex).matches?(candidate)
    rescue Regex::Error
      pin == candidate
    end

    # Parses the version column (3rd whitespace-separated field) out of
    # a `dpkg -l <pkg> | grep '^ii'` line, e.g. "ii  rabbitmq-server
    # 3.12.2-1  amd64  ...".
    private def installed_version(dpkg_line : String) : String?
      dpkg_line.split(/\s+/)[2]?
    end

    # One `dpkg-query` round trip for the WHOLE package list instead of
    # one `dpkg -l <pkg>` per package (N+1 remote commands on every
    # multi-package apt task). Returns installed-ness, the installed
    # version and the raw Status-Abbrev ("ii" installed, "rc" removed
    # with config files still on disk, ...) per requested base name; a
    # name dpkg has never heard of (never installed) simply has no line.
    # Keys are the bare name with any `:arch` suffix dpkg-query appends
    # for multi-arch packages stripped.
    private def dpkg_installed_status(packages : Array(String)) : Hash(String, {Bool, String?, String})
      statuses = Hash(String, {Bool, String?, String}).new
      return statuses if packages.empty?

      name_list = packages.map { |pkg| shell_single_quote(split_name_version(pkg)[0]) }.join(" ")
      result = remote_exec("dpkg-query -W -f='${db:Status-Abbrev} ${Version} ${Package}
' #{name_list} 2>/dev/null")
      result[:stdout].each_line do |line|
        parts = line.split(/\s+/, 3)
        next unless parts.size == 3
        bare = parts[2].strip.split(":").first
        next if statuses.has_key?(bare)
        installed = parts[0].starts_with?("ii")
        statuses[bare] = {installed, installed ? parts[1] : nil, parts[0]}
      end
      statuses
    end

    # Parses apt-get's own end-of-run summary line ("0 upgraded, 0 newly
    # installed, 0 to remove and N not upgraded.") to tell a genuine
    # no-op apart from real work done - the "0 upgraded, 0 newly
    # installed" case (a virtual package already satisfied by something
    # else installed, or every named package already at the requested
    # version) has exit code 0 just like a real install does. Defaults
    # to "had an effect" (changed: true) if the summary line's own shape
    # ever changes/isn't found, matching this codebase's usual
    # fail-toward-"changed" bias for an unparseable case.
    private def apt_summary_had_no_effect?(stdout : String) : Bool
      match = stdout.match(/(\d+) upgraded, (\d+) newly installed/)
      return false unless match
      match[1] == "0" && match[2] == "0"
    end

    # Handle `deb:` - install a local .deb file or a URL (downloaded to a
    # temp path first). Idempotency mirrors Ansible's own apt module:
    # read the package's own name+version out of the .deb's control
    # metadata via `dpkg-deb -f`, and skip the install if that exact
    # name/version is already installed.
    private def handle_deb(deb_source : String, messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      path = deb_source
      downloaded_tmp : String? = nil

      if deb_source.starts_with?("http://") || deb_source.starts_with?("https://")
        if @check_mode
          messages << "Would download #{deb_source} to a private /tmp staging file"
        else
          # File.tempfile (unguessable name + O_EXCL + 0600), not the
          # URL's own basename: /tmp/<basename> was fully predictable,
          # and curl -o follows a symlink planted there, clobbering an
          # arbitrary file as root.
          # The suffix is not cosmetic: command-line apt-get/dpkg refuse
          # non-.deb files with "E: Unsupported file ... given on
          # commandline" (Ansible's apt module uses python-apt, which
          # never sees the filename, so this only bit us).
          tmp = File.tempfile(".krikri-playbook-deb-", ".deb")
          path = tmp.path
          downloaded_tmp = tmp.path
          tmp.close
          download_result = remote_exec("curl -fsSL -o #{shell_single_quote(path)} #{shell_single_quote(deb_source)}")
          if download_result[:exit_code] != 0
            File.delete(path) rescue nil
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to download #{deb_source}: #{download_result[:stderr]}"
            )
          end
        end
      end

      # Ansible's fetch_file registers the downloaded temp with
      # module.add_cleanup_file, so it lives for the whole module run
      # (the very next thing apt.py does with it is `dpkg-deb -f`) and is
      # removed only at module exit. An ensure-scoped delete around just
      # the download removed the file before that first metadata read,
      # failing every URL deb: with "No such file or directory"
      # (round900223, j91321.sysmon's packages-microsoft-prod.deb task).
      begin
        install_deb_file(path, lock_timeout, messages, changed)
      ensure
        File.delete(downloaded_tmp) if downloaded_tmp
      end
    end

    # The metadata-read + idempotency + install half of #handle_deb,
    # shared by the URL (downloaded temp path) and local-file cases so a
    # local deb: path never gains URL-only behavior.
    private def install_deb_file(path : String, lock_timeout : Int32, messages : Array(String), changed : Bool) : PluginResult
      # python-apt's DebPackage construction is the FIRST thing real
      # install_deb does, and its SystemError text IS the registered
      # failure msg ("Unable to install package: <e>" - round-99500x
      # captures apt_fail_deb_missing/_corrupt/_dir):
      #   - a missing file:  E:Could not open file <path> - open (2: No such file or directory)
      #   - a directory:     E:Read error - read (21: Is a directory)
      #   - a non-archive:   E:Invalid archive signature (the 8-byte ar
      #     magic "!<arch>\n" is the first thing apt_pkg validates)
      unless File.exists?(path)
        return unable_to_install("E:Could not open file #{path} - open (2: No such file or directory)")
      end
      if File.directory?(path)
        return unable_to_install("E:Read error - read (21: Is a directory)")
      end
      magic = Bytes.new(8)
      begin
        File.open(path, "r") { |io| io.read_fully(magic) }
      rescue File::Error
        # an unreadable file lets the metadata read below produce the
        # failure, as before
        magic = "!<arch>\n".to_slice
      end
      unless magic == "!<arch>\n".to_slice
        return unable_to_install("E:Invalid archive signature")
      end

      # Read the .deb's own control metadata: the name/version identity
      # Ansible's apt module checks against dpkg's installed-package
      # database for idempotency, plus the dependency fields real
      # install_deb resolves BEFORE any dpkg run (DebPackage.depends
      # folds Depends AND Pre-Depends; Recommends joins in only when
      # install_recommends is explicitly true) - one dpkg-deb -f call
      # for all of them.
      info_result = remote_exec("dpkg-deb -f #{shell_single_quote(path)} Package Version Pre-Depends Depends Recommends")
      if info_result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read package metadata from #{path}: #{info_result[:stderr]}"
        )
      end

      fields = parse_deb_control_fields(info_result[:stdout])
      pkg_name = fields["Package"]?
      pkg_version = fields["Version"]?

      installed_deb_ver : String? = nil
      if pkg_name && pkg_version
        check_result = remote_exec("dpkg -l #{shell_single_quote(pkg_name)} 2>/dev/null | grep '^ii'")
        if check_result[:exit_code] == 0
          installed_deb_ver = installed_version(check_result[:stdout])
          if installed_deb_ver == pkg_version
            # Real install_deb's already-installed exit: the deps install
            # produced no retvals, so exit_json(changed=False,
            # stdout='', stderr='', diff='') - diff is the EMPTY STRING,
            # not a dict (round-99500x apt_real_deb_again capture), and
            # there is no msg key.
            return PluginResult.new(changed: false, failed: false,
              stdout: "", stderr: "", diff: JSON::Any.new(""),
              key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"])
          end
        end
      end

      # Real install_deb, past the same-version skip, runs pkg.check()
      # before anything is installed. Its version gate fires first: a deb
      # OLDER than the installed version fails with "A later version is
      # already installed" (a plain fail_json(msg=...), the round-1100002
      # apt_fail_deb capture's [failed, msg, changed, exception] shape)
      # unless force: or allow_downgrade: releases it - allow_downgrade
      # by explicitly passing on that one failure string. The comparison
      # goes through dpkg's own Debian-version ordering (not a
      # reimplemented comparator) and only when the name is installed at
      # a DIFFERENT version than the deb carries.
      if installed_deb_ver && pkg_version && installed_deb_ver != pkg_version &&
         !@force && !@allow_downgrade &&
         dpkg_version_compares([{installed_deb_ver.not_nil!, ">", pkg_version.not_nil!}])[0]
        return PluginResult.new(changed: false, failed: true,
          msg: "A later version is already installed")
      end

      # DebPackage.check()'s dependency half, CLI-mirrored: the .deb's
      # own Depends/Pre-Depends are resolved BEFORE the dpkg run - missing
      # dependencies go through the normal install() machinery first,
      # because `dpkg -i` itself cannot resolve dependencies and dies on
      # "dependency problems prevent configuration" (round-1200xxx:
      # appsilon.r_language, JonasPammer/kso512.checkmk_server,
      # Oefenweb.rstudio_server all failed exactly there while real
      # ansible-playbook pre-installed the missing deps and succeeded).
      # The or-group rules mirror python-apt: a group is satisfied when
      # any alternative is installed at a constraint-satisfying version
      # (unversioned deps are satisfied by the bare installed name);
      # otherwise the first alternative apt can actually install wins -
      # unknown names and purely virtual ones ("Candidate: (none)") are
      # skipped the way _satisfy_or_group skips them, and a group with no
      # selectable alternative fails check() with "Dependency is not
      # satisfiable: <or-group>". (python-apt additionally resolves a
      # virtual dep through a lone provider and honors Provides:-based
      # satisfaction for unversioned deps - neither is reachable without
      # an in-process apt cache here; those fall through to apt-get's own
      # handling, which errors where python-apt would have auto-picked.)
      deps_to_install = [] of String
      dep_groups = parse_dep_string(fields["Depends"]?) + parse_dep_string(fields["Pre-Depends"]?)
      unless dep_groups.empty?
        dep_alt_names = Set(String).new
        dep_groups.each do |alternatives|
          alternatives.each { |alternative| dep_alt_names << alternative.name }
        end
        statuses = dpkg_installed_status(dep_alt_names.to_a.map(&.split(":").first))
        # Every version constraint an INSTALLED alternative can answer,
        # in one batched dpkg --compare-versions round trip.
        compare_pairs = [] of {String, String, String}
        sat_pair_group = [] of Int32
        dep_groups.each_with_index do |alternatives, group_idx|
          alternatives.each do |alternative|
            next unless alternative.oper && alternative.version
            st = statuses[alternative.name.split(":").first]?
            next unless st && st[0] && st[1]
            compare_pairs << {st[1].not_nil!, alternative.oper.not_nil!, alternative.version.not_nil!}
            sat_pair_group << group_idx
          end
        end
        sat_answers = dpkg_version_compares(compare_pairs)

        group_satisfied = Array(Bool).new(dep_groups.size, false)
        sat_answers.each_with_index do |satisfied, i|
          group_satisfied[sat_pair_group[i]] = true if satisfied
        end
        unsatisfied = [] of Array(DebDepAlternative)
        dep_groups.each_with_index do |alternatives, group_idx|
          next if group_satisfied[group_idx]
          # an installed alternative with NO version constraint satisfies
          # its group outright (python-apt's unversioned installed check)
          group_satisfied[group_idx] = alternatives.any? do |alternative|
            next false if alternative.oper || alternative.version
            st = statuses[alternative.name.split(":").first]?
            st && st[0]
          end
          unsatisfied << alternatives unless group_satisfied[group_idx]
        end

        # One apt-cache policy round trip per batch for every alternative
        # of the unsatisfied groups (see #apt_candidates_batch).
        unsatisfied_alt_names = Set(String).new
        unsatisfied.each do |alternatives|
          alternatives.each { |alternative| unsatisfied_alt_names << alternative.name }
        end
        candidates = apt_candidates_batch(unsatisfied_alt_names.to_a)

        # python-apt's provider paths for a name the apt cache knows only
        # as virtual (Provides:), e.g. jammy's check-mk-raw Depends:
        # "libffi8ubuntu1" where the archive only has libffi8 (=
        # 3.4.2-4), Provides: libffi8ubuntu1 - round-1300024/1300039
        # checkmk_server failed "Dependency is not satisfiable:
        # libffi8ubuntu1" here while real ansible's DebPackage satisfied
        # the group through the installed provider. showpkg's Reverse
        # Provides section is the only CLI window onto apt_pkg's provider
        # table, so the provider walks batch there. Upstream semantics
        # mirrored: _is_or_group_satisfied treats an INSTALLED provider
        # as satisfying the group outright (ignoring the version
        # constraint - upstream's virtual check never consults it), both
        # for a purely-virtual name and for an unversioned name that is
        # real-but-uninstalled; _satisfy_or_group installs a purely
        # virtual name's EXACTLY ONE provider (constraint checked
        # against that provider's candidate like any other alternative),
        # and skips names with more than one provider (upstream's
        # len(providers) != 1 guard).
        provider_probe_names = Set(String).new
        unsatisfied.each do |alternatives|
          alternatives.each do |alternative|
            res = candidates[alternative.name]?
            next unless res && res[0]
            provider_probe_names << alternative.name if res[1].nil? || !alternative.oper
          end
        end
        providers_map = apt_reverse_provides_batch(provider_probe_names.to_a)
        provider_names = Set(String).new
        providers_map.each_value do |providers|
          providers.each do |provider|
            provider_names << provider.split(":").first
          end
        end
        provider_statuses = provider_names.empty? ? Hash(String, {Bool, String?, String}).new : dpkg_installed_status(provider_names.to_a)
        provider_candidates = provider_names.empty? ? Hash(String, {Bool, String?}).new : apt_candidates_batch(provider_names.to_a)

        res_pairs = [] of {String, String, String}
        res_pair_slot = Hash({Int32, Int32}, Int32).new
        prov_pair_slot = Hash({Int32, Int32}, Int32).new
        unsatisfied.each_with_index do |alternatives, group_idx|
          alternatives.each_with_index do |alternative, alt_idx|
            res = candidates[alternative.name]?
            next unless res && res[0] && res[1]
            next unless alternative.oper && alternative.version
            res_pair_slot[{group_idx, alt_idx}] = res_pairs.size
            res_pairs << {res[1].not_nil!, alternative.oper.not_nil!, alternative.version.not_nil!}
          end
        end
        unsatisfied.each_with_index do |alternatives, group_idx|
          alternatives.each_with_index do |alternative, alt_idx|
            res = candidates[alternative.name]?
            next unless res && res[0] && res[1].nil?
            next unless alternative.oper && alternative.version
            providers = providers_map[alternative.name]?
            next unless providers && providers.size == 1
            provider = providers[0].split(":").first
            next if provider_statuses[provider]?.try(&.[0])
            pres = provider_candidates[provider]?
            next unless pres && pres[0] && pres[1]
            prov_pair_slot[{group_idx, alt_idx}] = res_pairs.size
            res_pairs << {pres[1].not_nil!, alternative.oper.not_nil!, alternative.version.not_nil!}
          end
        end
        res_answers = dpkg_version_compares(res_pairs)

        unsatisfied.each_with_index do |alternatives, group_idx|
          # _is_or_group_satisfied runs before _satisfy_or_group for the
          # WHOLE group, so an installed provider on ANY alternative
          # preempts the install-a-provider walk of an earlier one.
          provider_satisfied = alternatives.any? do |alternative|
            res = candidates[alternative.name]?
            next false unless res && res[0]
            next false unless res[1].nil? || !alternative.oper
            providers = providers_map[alternative.name]?
            providers && providers.any? { |provider| provider_statuses[provider.split(":").first]?.try(&.[0]) }
          end
          next if provider_satisfied
          pick : String? = nil
          alternatives.each_with_index do |alternative, alt_idx|
            res = candidates[alternative.name]?
            next unless res && res[0]
            if res[1]
              if alternative.oper && alternative.version
                if pi = res_pair_slot[{group_idx, alt_idx}]?
                  pick = alternative.name if res_answers[pi]
                end
              else
                pick = alternative.name
              end
            else
              # purely virtual: only a single provider can be picked
              providers = providers_map[alternative.name]?
              next unless providers && providers.size == 1
              provider = providers[0].split(":").first
              pres = provider_candidates[provider]?
              next unless pres && pres[0] && pres[1]
              if alternative.oper && alternative.version
                if pi = prov_pair_slot[{group_idx, alt_idx}]?
                  pick = provider if res_answers[pi]
                end
              else
                pick = provider
              end
            end
            break if pick
          end
          unless pick
            # DebPackage._satisfy_or_group's own failure: the ONLY
            # fail_json check() produces before install() ever runs -
            # the plain [failed, msg, changed, exception] shape, with the
            # msg carrying the trailing "\n" of the gettext string.
            return PluginResult.new(changed: false, failed: true,
              msg: "Dependency is not satisfiable: #{dep_or_str(alternatives)}\n")
          end
          deps_to_install << pick
        end
      end

      # Real install_deb's Recommends handling, verbatim INCLUDING its
      # wart: with install_recommends explicitly true the raw Recommends
      # field is split on WHITESPACE and every token joins the deps list
      # ("a, b (>= 1)" becomes the specs "a," "b" "(>=" "1)") - upstream
      # hands those to install() unfiltered, where a junk token fails
      # "No package matching '(>=' is available" like any other unknown
      # name. An unset install_recommends (None) is falsy upstream and
      # skips the field entirely.
      if @install_recommends == true && (rec = fields["Recommends"]?)
        deps_to_install.concat(rec.split)
      end

      # The deps install through install()'s own machinery, then - only
      # once it succeeded - the dpkg run, exactly install_deb's sequence.
      # Its failure retvals (msg/stdout/stderr/rc, NO cache keys -
      # install_deb exits before main()'s cache-key append) are re-failed
      # as-is: fail_json(**retvals) captures msg as its named parameter
      # and re-adds it AFTER kwargs, so the registered order is
      # [stdout, stderr, rc, failed, msg, *_lines] - the same kwargs rule
      # that puts msg after failed in the round-99500x
      # apt_fail_install_dpkgopt capture (where main()'s cache keys sit
      # between rc and failed).
      deps_stdout = ""
      deps_stderr = ""
      deps_diff_prepared : String? = nil
      deps_had_retvals = false
      unless deps_to_install.empty?
        deps_result = handle_install(deps_to_install, messages, changed, lock_timeout, deb_deps: true)
        if deps_result.failed?
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: deps_result.msg,
            stdout: deps_result.extra["stdout"]?.try(&.as_s) || "",
            stderr: deps_result.extra["stderr"]?.try(&.as_s) || "",
            rc: deps_result.extra["rc"]?.try(&.as_i) || 1,
            key_order: ["stdout", "stderr", "rc", "failed", "msg", "stdout_lines", "stderr_lines"]
          )
        end
        if deps_result.extra.has_key?("stdout")
          # install() ran apt-get: retvals = {changed, stdout, stderr,
          # diff}. The all-deps-already-installed case produces the bare
          # {changed: False} retvals with no stdout at all, which merges
          # below exactly like an empty retvals dict.
          deps_stdout = deps_result.extra["stdout"].as_s
          deps_stderr = deps_result.extra["stderr"].as_s
          deps_had_retvals = true
          deps_diff_prepared = deps_result.diff.try(&.as_h?).try(&.["prepared"]?).try(&.as_s)
        end
      end

      # Real install_deb's dpkg invocation: `dpkg <options> -i <debs>`
      # with options = the raw dpkg_options: list as --flags, plus
      # --simulate in check mode and --force-all under force:. The exact
      # string is the registered failure msg ("<cmd> failed" - no err
      # text, no quotes, no rc key; round-99500x apt_fail_deb_preinst
      # capture), so it is built verbatim.
      dpkg_flags = @dpkg_options.split(",").map(&.strip).reject(&.empty?)
        .map { |opt| "--#{opt}" }.join(" ")
      dpkg_flags += " --simulate" if @check_mode
      dpkg_flags += " --force-all" if @force
      dpkg_cmd = "dpkg #{dpkg_flags} -i #{path}"

      # Check mode: Ansible still RUNS the command - with --simulate - and
      # registers its output (round-99500x apt_check_deb capture:
      # changed=True, the simulate output as stdout, parse_diff ALWAYS
      # applied here - install_deb has no m._diff guard, unlike
      # install()/remove()).
      deb_result = with_policy_rc_d { apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive dpkg #{dpkg_flags} -i #{shell_single_quote(path)}", lock_timeout, ->remote_exec(String)) }
      if deb_result[:exit_code] == 0 || @check_mode
        unless deb_result[:exit_code] == 0
          # a --simulate run failing is Ansible's same "<cmd> failed" shape
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "#{dpkg_cmd} failed",
            stdout: deps_stdout + deb_result[:stdout],
            stderr: deps_stderr + deb_result[:stderr],
            key_order: ["stdout", "stderr", "failed", "msg", "stdout_lines", "stderr_lines"]
          )
        end
        # Real install_deb's success exit: exit_json(changed=True,
        # stdout=stdout, stderr=stderr, diff=diff) with the deps install's
        # retvals merged in - stdout/stderr CONCATENATED (deps output
        # first), and diff following install_deb's own merge rule: when
        # retvals carried a diff (deps reached apt-get), its `prepared`
        # grows by the dpkg output in diff mode and the diff stays the
        # bare {} retvals carried in non-diff mode; with no deps retvals
        # at all, diff is parse_diff(dpkg out) with NO diff-mode guard.
        if deps_had_retvals
          merged_diff = if prepared = deps_diff_prepared
                          JSON.parse({"prepared" => "#{prepared}\n\n#{deb_result[:stdout]}"}.to_json)
                        else
                          JSON.parse("{}")
                        end
          return PluginResult.new(changed: true, failed: false,
            stdout: deps_stdout + deb_result[:stdout],
            stderr: deps_stderr + deb_result[:stderr],
            diff: merged_diff,
            key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"])
        end
        return PluginResult.new(changed: true, failed: false,
          stdout: deb_result[:stdout],
          stderr: deb_result[:stderr],
          diff: apt_install_diff(deb_result[:stdout]),
          key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"])
      end

      # dpkg failed after the deps install succeeded (or with no deps at
      # all, e.g. a failing preinst script): Ansible's "<cmd> failed"
      # shape over the same merged stdout/stderr.
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "#{dpkg_cmd} failed",
        stdout: deps_stdout + deb_result[:stdout],
        stderr: deps_stderr + deb_result[:stderr],
        key_order: ["stdout", "stderr", "failed", "msg", "stdout_lines", "stderr_lines"]
      )
    end

    # Real install_deb's DebPackage-construction failure: fail_json with
    # the plain kwargs-first shape ([failed, msg, changed, exception]).
    private def unable_to_install(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Unable to install package: #{detail}")
    end

    # Parses the control-field dump `dpkg-deb -f <deb> F1 F2 ...` prints
    # ("Name: value" lines; folded continuation lines start with
    # whitespace and join their field with a single space) into a
    # name->value map. A requested-but-absent field simply has no entry.
    private def parse_deb_control_fields(stdout : String) : Hash(String, String)
      fields = {} of String => String
      current : String? = nil
      stdout.each_line do |line|
        if (line.starts_with?(' ') || line.starts_with?('\t')) && (cur = current)
          fields[cur] = "#{fields[cur]} #{line.strip}"
        elsif (m = line.match(/^([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(.*)$/))
          current = m[1]
          fields[current.not_nil!] = m[2].strip
        end
      end
      fields
    end

    # One alternative of a dependency or-group: the bare package name
    # (any :arch suffix kept verbatim) plus its optional version
    # constraint operands. Architecture lists and profile restrictions
    # are parsed past and never consulted, matching what this CLI-level
    # mirror can act on.
    private struct DebDepAlternative
      getter name : String
      getter oper : String?
      getter version : String?

      def initialize(@name, @oper, @version)
      end
    end

    # apt_pkg.parse_depends's structure: comma-separated groups, each a
    # '|' list of alternatives, each with an optional "(op version)"
    # constraint. Empty segments drop out (a trailing comma or empty
    # group is not a dependency).
    private def parse_dep_string(value : String?) : Array(Array(DebDepAlternative))
      return [] of Array(DebDepAlternative) unless value
      groups = [] of Array(DebDepAlternative)
      value.split(",").each do |group|
        alts = group.split("|").compact_map do |raw|
          s = raw.strip
          next nil if s.empty?
          name_match = s.match(/^[^\s(\[<]+/)
          next nil unless name_match
          oper : String? = nil
          version : String? = nil
          if cm = s.match(/\((<<|<=|<|>>|>=|>|=)\s+([^)]+)\)/)
            oper = cm[1]
            version = cm[2].strip
          end
          DebDepAlternative.new(name_match[0], oper, version)
        end
        groups << alts unless alts.empty?
      end
      groups
    end

    # DebPackage._satisfy_or_group's failure-string serialization of one
    # or-group: "name" or "name (oper version)", alternatives joined by
    # "|".
    private def dep_or_str(alternatives : Array(DebDepAlternative)) : String
      alternatives.map do |alternative|
        alternative.oper && alternative.version ? "#{alternative.name} (#{alternative.oper} #{alternative.version})" : alternative.name
      end.join("|")
    end

    # One batched `dpkg --compare-versions` round trip for every
    # constraint/version comparison a deb: install needs (dpkg's own
    # Debian version ordering - epoch, tilde, letter-vs-number - is not
    # reimplemented here). Each pair evaluates
    # `dpkg --compare-versions 'a' '<op>' 'b'` and answers on its own
    # "K<n>=Y/N" marker line; a pair whose dpkg invocation errors answers
    # false (the && || chain still emits the marker).
    private def dpkg_version_compares(pairs : Array({String, String, String})) : Array(Bool)
      return [] of Bool if pairs.empty?
      cmd = pairs.map_with_index do |(a, op, b), i|
        "dpkg --compare-versions #{shell_single_quote(a)} #{shell_single_quote(op)} #{shell_single_quote(b)} && echo 'K#{i}=Y' || echo 'K#{i}=N'"
      end.join("; ")
      result = remote_exec(cmd)
      answers = Array(Bool).new(pairs.size, false)
      result[:stdout].each_line do |line|
        if (m = line.match(/^K(\d+)=(Y|N)\s*$/)) && (idx = m[1].to_i) < pairs.size
          answers[idx] = m[2] == "Y"
        end
      end
      answers
    end

    # Batched form of #apt_candidate for the deb: dependency resolution:
    # one apt-cache policy round trip for a whole list of names, with a
    # marker line between probes. Same per-name semantics as its
    # single-name sibling: no stanza at all -> unknown (false, nil),
    # "Candidate: (none)"/empty -> known but purely virtual (true, nil),
    # otherwise (true, candidate version).
    private def apt_candidates_batch(names : Array(String)) : Hash(String, {Bool, String?})
      result = {} of String => {Bool, String?}
      return result if names.empty?
      probes = names.map do |name|
        "echo #{shell_single_quote("==KRIKRI-POLICY== #{name}")}; apt-cache policy #{shell_single_quote(name)} 2>/dev/null"
      end.join("; ")
      probe = remote_exec(probes)
      current : String? = nil
      probe[:stdout].each_line do |line|
        if line.starts_with?("==KRIKRI-POLICY== ")
          current = line.lchop("==KRIKRI-POLICY== ").strip
          result[current] = {false, nil}
        elsif (cur = current) && line.strip.starts_with?("Candidate:")
          version = line.split("Candidate:")[1]?.try(&.strip) || ""
          result[cur] = {true, version.empty? || version == "(none)" ? nil : version}
        end
      end
      result
    end

    # Batched form of python-apt's get_providing_packages, for the deb:
    # dependency provider walks: one `apt-cache showpkg` round trip per
    # batch of names, marker lines between probes. Every "name version
    # (= ver)" entry under a probe's "Reverse Provides:" section yields
    # one provider name (arch-qualified entries collapse to their base
    # name, and duplicates drop out); a probe with no Reverse Provides
    # section, or with none listed, has no providers.
    private def apt_reverse_provides_batch(names : Array(String)) : Hash(String, Array(String))
      result = {} of String => Array(String)
      return result if names.empty?
      probes = names.map do |name|
        "echo #{shell_single_quote("==KRIKRI-PROVIDES== #{name}")}; apt-cache showpkg #{shell_single_quote(name)} 2>/dev/null"
      end.join("; ")
      probe = remote_exec(probes)
      current : String? = nil
      in_reverse = false
      probe[:stdout].each_line do |line|
        if line.starts_with?("==KRIKRI-PROVIDES== ")
          current = line.lchop("==KRIKRI-PROVIDES== ").strip
          result[current] = [] of String
          in_reverse = false
        elsif cur = current
          if line.strip == "Reverse Provides:"
            in_reverse = true
          elsif in_reverse
            if line.strip.empty?
              in_reverse = false
            elsif provider = line.strip.split[0]?
              name = provider.split(":").first
              result[cur] << name unless result[cur].includes?(name)
            end
          end
        end
      end
      result
    end

    # Handle installing packages. build_dep: is real apt.py's
    # state=build-dep (install() with build_dep=True: every spec goes to
    # `apt-get build-dep` verbatim, no installed-status short-circuit);
    # fixed_state: is state=fixed (the normal install path plus
    # --fix-broken); deb_deps: is install_deb()'s dependency pre-install
    # call, which passes NONE of force/autoremove/only_upgrade/
    # default_release to install() (its own kwargs fix them at their
    # defaults) while fail_on_autoremove and the allow_* flags still
    # travel through.
    private def handle_install(packages : Array(String), messages : Array(String), changed : Bool, lock_timeout : Int32, build_dep : Bool = false, fixed_state : Bool = false, deb_deps : Bool = false) : PluginResult
      # An empty package name (from `name: ""` or an empty comma
      # segment - parse_package_names keeps those now) is a hard failure
      # in Ansible's apt module, same as any other name missing
      # from the cache: "No package matching '' is available"
      # (live-verified vs ansible-playbook 2.19.11 in check mode for
      # state present AND latest; state absent with an empty name is
      # just "ok" there, so handle_remove deliberately has no guard).
      if packages.any?(&.empty?)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "No package matching '' is available"
        )
      end

      to_install = [] of String
      already_installed = [] of String
      install_stdout = ""
      install_stderr = ""

      # One batched dpkg-query round trip for the whole list (see
      # dpkg_installed_status), shared by the candidate probe and the
      # to_install split below.
      installed_status = dpkg_installed_status(packages)

      # Ansible's install() resolves each spec against the apt cache
      # BEFORE running apt-get, failing on the first spec it can't
      # satisfy (live-verified wordings via the podman-diff
      # apt_edge_cases A4/A5 cases):
      #   - an unknown package name: "No package matching 'X' is
      #     available"
      #   - an unknown pinned version on a known package: "no available
      #     installation candidate for X=V"
      # Previously this engine deferred both to `apt-get install`'s own
      # "E: Unable to locate package ..."/"E: Version ... was not found"
      # and wrapped them in a "Failed to install ...: <stderr>" msg -
      # entirely different wording, and the same wrong-first-error for a
      # name LIST where Ansible fails on the first unsatisfiable spec.
      # Real install()'s spec construction resolves each plain name to
      # its candidate version and pins it onto the apt-get spec
      # ("'tree=2.0.2-1'"), so the resolved candidate is captured here
      # alongside the resolvability check. A name whose Candidate: is
      # "(none)" (purely virtual) stays bare, matching Ansible's
      # version_installable=True path.
      candidates = {} of String => String?
      unless build_dep
        packages.each do |pkg|
          base_name, pinned_version = split_name_version(pkg)
          installed_probe, installed_ver_probe = installed_status[base_name]?.try { |pair| pair } || {false, nil}
          # installed specs never reach the candidate check (Ansible's
          # installed_version short-circuit)
          next if installed_probe && (pinned_version.nil? || ((iv = installed_ver_probe) && version_pin_matches?(pinned_version, iv)))
          next if @only_upgrade && !installed_probe
          if pinned_version
            unless pinned_version_installable?(base_name, pinned_version)
              # Ansible's failure travels through install()'s retvals into
              # fail_json - main() appends the cache keys BEFORE the
              # failed/msg pair lands (round-99500x apt_fail_candidate
              # capture: [cache_updated, cache_update_time, failed, msg,
              # changed]).
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "no available installation candidate for #{pkg}",
                cache_update_time: @cache_update_time,
                key_order: ["cache_updated", "cache_update_time", "failed", "msg"]
              )
            end
          else
            resolvable, candidate = apt_candidate(base_name)
            unless resolvable
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "No package matching '#{base_name}' is available"
              )
            end
            candidates[base_name] = candidate
          end
        end
      end

      # Check which packages need installation.
      packages.each do |pkg|
        next if build_dep
        base_name, pinned_version = split_name_version(pkg)
        installed, installed_ver = installed_status[base_name]?.try { |pair| pair } || {false, nil}
        if installed && (pinned_version.nil? || installed_ver == pinned_version)
          already_installed << pkg
        elsif !installed && @only_upgrade
          # Ansible's install(): `if not installed and only_upgrade:
          # continue` - only_upgrade upgrades already-installed packages
          # and never newly installs one. The --only-upgrade flag passed
          # below makes apt-get itself skip these the same way.
          next
        else
          to_install << pkg
        end
      end
      to_install = packages if build_dep

      # Install packages that aren't already installed - in CHECK MODE
      # too: real apt.py builds the same command with `--simulate` in
      # check_arg's slot, RUNS it, and registers its output as stdout
      # (round-99500x apt_check_install capture: the simulate output,
      # stderr "", diff {}, the cache keys, the *_lines pairs).
      unless to_install.empty?
        # Real install()'s spec quoting: plain Python "'%s'" wrapping,
        # no shell escaping - and each plain (unpinned) name carries its
        # resolved candidate version ("'tree=2.0.2-1'"), captured above.
        # build_dep passes every spec through verbatim (quoted, no
        # version pin).
        pkg_list = to_install.map { |pkg| naive_single_quote(build_dep ? pkg : install_spec(pkg, candidates)) }.join(" ")

        # Real install()'s EXACT command format: "%s -y %s %s %s %s %s
        # %s %s install %s" over (APT_GET_CMD, dpkg_options,
        # only_upgrade, fixed, force_yes, autoremove, fail_on_autoremove,
        # check_arg, packages) - the empty flag fields KEEP their
        # separators, so the default shape carries the seven-space run
        # before "install" that Ansible's "'cmd' failed" msg shows
        # (round-99500x apt_fail_install_dpkgopt capture). build_dep's
        # own format has no autoremove slot ("%s -y %s %s %s %s %s %s
        # build-dep %s").
        flags = [
          real_dpkg_options(lock_timeout),
          (!deb_deps && @only_upgrade) ? "--only-upgrade" : "",
          fixed_state ? "--fix-broken" : "",
          (!deb_deps && @force) ? "--force-yes" : "",
        ] of String
        flags << (!deb_deps && true?(@params["autoremove"]?) ? "--auto-remove" : "") unless build_dep
        flags << (@fail_on_autoremove ? "--no-remove" : "")
        flags << (@check_mode ? "--simulate" : "")
        install_cmd = "#{apt_get_bin} -y #{flags.join(" ")} #{build_dep ? "build-dep" : "install"} #{pkg_list}#{apt_install_trailing_flags(!deb_deps)}"

        # Real sets DEBIAN_FRONTEND (and DEBIAN_PRIORITY/LC_*) via
        # run_command_environ_update, NOT in the command string - the
        # env prefix here is execution plumbing only and never reaches a
        # registered msg.
        exec_cmd = "DEBIAN_FRONTEND=noninteractive #{install_cmd}"
        # `apt-get install` of named packages contends for the dpkg lock
        # - wrap with lock_timeout retry, matching Ansible's
        # `apt` module behavior. Also wraps Ansible's implicit
        # recovery from a corrupt/unparseable on-disk package index: on
        # that specific failure (not a plain locate-miss on a valid
        # cache) the whole install is retried once behind an implicit
        # `apt-get update` - Ansible only does that at cache-acquisition
        # time, and check mode never runs the update, so check mode gets
        # the plain lock retry only.
        install_result = if @check_mode
                           with_policy_rc_d { apt_with_lock_retry(exec_cmd, lock_timeout, ->remote_exec(String)) }
                         else
                           with_policy_rc_d { apt_install_with_implicit_cache_retry(exec_cmd, lock_timeout, ->remote_exec(String)) }
                         end
        install_stdout = install_result[:stdout]
        install_stderr = install_result[:stderr]
        if install_result[:exit_code] == 0
          # A requested name can be a virtual package already satisfied
          # by something else installed (`rubygems` - not a real
          # package on modern Debian/Ubuntu at all, only a virtual one
          # `ruby`'s own package Provides: - apt-get install then
          # genuinely does nothing) - dpkg -l's own is-it-already-
          # installed pre-check above only ever looks up the literal
          # requested name, which a purely virtual package never has a
          # real dpkg entry for, so it always fell through to "needs
          # install" here. Real apt-get's own exit code is 0 either
          # way, so trusting exit_code alone previously always
          # reported changed: true even when apt's own summary line
          # shows "0 upgraded, 0 newly installed" - Ansible's own
          # apt module (python-apt bindings, not this CLI-based
          # shell-out) correctly resolves the Provides: relationship
          # and reports changed: false here.
          # changed stays false when apt's own summary shows nothing was
          # actually installed (see the virtual-package comment above);
          # check mode matches Ansible's unconditional changed=True for a
          # reached-apt-get install.
          if @check_mode || !apt_summary_had_no_effect?(install_result[:stdout])
            changed = true
          end
        else
          # Real install() failure: data = dict(msg="'%s' failed: %s" %
          # (cmd, err), stdout=out, stderr=err, rc=rc), then main()
          # appends cache_updated/cache_update_time, and fail_json puts
          # the kwargs FIRST and failed/msg after them (round-99500x
          # apt_fail_install_dpkgopt capture: [stdout, stderr, rc,
          # cache_updated, cache_update_time, failed, msg, stdout_lines,
          # stderr_lines]).
          return PluginResult.new(
            changed: changed,
            failed: true,
            msg: "'#{install_cmd}' failed: #{install_result[:stderr]}",
            stdout: install_result[:stdout],
            stderr: install_result[:stderr],
            rc: install_result[:exit_code],
            cache_update_time: @cache_update_time,
            key_order: ["stdout", "stderr", "rc", "cache_updated", "cache_update_time", "failed", "msg", "stdout_lines", "stderr_lines"]
          )
        end
      end

      # Real apt.py's install(): an all-already-installed package list
      # builds an EMPTY apt-get command line (`packages = ''` after the
      # per-spec installed check skips every entry) and exits with the
      # bare `data = dict(changed=False)` retvals - no stdout/stderr/msg
      # and therefore no controller-appended stdout_lines/stderr_lines
      # (round-992002 ufw_helper_install capture:
      # [changed, cache_updated, cache_update_time, failed]). Only a
      # package that actually reaches apt-get produces the
      # [changed, stdout, stderr, diff, ...] shape below.
      if to_install.empty?
        return PluginResult.new(
          changed: false,
          failed: false,
          cache_update_time: @cache_update_time,
          key_order: ["changed", "cache_updated", "cache_update_time"]
        )
      end

      # Real apt.py's install-path exit: exit_json(**retvals) with
      # retvals = {changed, stdout, stderr, diff} + cache_updated/
      # cache_update_time (live-verified against Ansible 2.19.11 via a
      # registered {{ r | to_json }} dump in the podman container, and
      # against the round-992003 zfs_helper_install capture:
      # [changed, stdout, stderr, diff, cache_updated, cache_update_time,
      # stdout_lines, stderr_lines, failed]). There is NO msg key on
      # either install shape - the per-package "already installed"/
      # "installed" wording this engine used to invent is not part of
      # Ansible's result - and `diff` is ALWAYS present once packages reach
      # apt-get (a bare {} when diff mode is off, parse_diff's
      # {prepared: ...} slice of apt-get's own output when on). The
      # controller appends stdout_lines/stderr_lines.
      # diff mode off: a bare {} (real apt.py: `diff = {}` unless
      # m._diff); diff mode on: parse_diff's prepared slice. The
      # stdout_lines/stderr_lines pair is emitted MODULE-side (like the
      # command/shell plugins) rather than left to the executor's
      # post-backfill, so the registered order matches Ansible's - real
      # appends stdout_lines/stderr_lines BEFORE its failed backfill.
      diff = @diff_mode ? apt_install_diff(install_stdout) : JSON.parse("{}")
      PluginResult.new(
        changed: changed,
        failed: false,
        stdout: install_stdout,
        stderr: install_stderr,
        diff: diff,
        stdout_lines: PluginHelpers::AnsibleSplitlines.split(install_stdout),
        stderr_lines: PluginHelpers::AnsibleSplitlines.split(install_stderr),
        cache_update_time: @cache_update_time,
        key_order: ["changed", "stdout", "stderr", "diff", "cache_updated", "cache_update_time", "stdout_lines", "stderr_lines"]
      )
    end

    # Real apt.py's parse_diff() over the apt-get output: everything
    # after the "Resolving dependencies..." (aptitude) or "Reading state
    # information..." (apt-get) marker line up to and including the
    # "N upgraded" summary line, joined into a single `prepared` string;
    # with no markers, everything. The diff-mode-only half of the
    # install path's always-present `diff` key (see above).
    private def apt_install_diff(output : String) : JSON::Any
      lines = output.lines
      start = (lines.index("Resolving dependencies...") || lines.index("Reading state information...")).try(&.+(1)) || 0
      stop = (lines.index { |line| line.matches?(/^\d+ (packages )?upgraded/) }).try(&.+(1)) || lines.size
      stop = start if stop < start
      JSON.parse({"prepared" => lines[start...stop].join("\n")}.to_json)
    end

    # Handle removing packages
    private def handle_remove(packages : Array(String), lock_timeout : Int32) : PluginResult
      to_remove = [] of String

      # Check which packages need removal - state: absent removes by
      # NAME regardless of any `=version` pin (matching real apt-get
      # remove semantics), so only the base name is checked here. One
      # batched query for the whole list (see dpkg_installed_status).
      # With purge: true, Ansible's remove() also includes packages
      # that aren't installed but still have files on the filesystem
      # (dpkg 'removed but config-files remain' state - `has_files and
      # purge` in apt.py): those still need a purge pass to drop the
      # leftover config.
      installed_status = dpkg_installed_status(packages)
      packages.each do |pkg|
        base_name, _ = split_name_version(pkg)
        installed, _, abbrev = installed_status[base_name]?.try { |triple| triple } || {false, nil, ""}
        if installed || (@purge && !installed && abbrev.includes?('c'))
          to_remove << pkg
        end
      end

      # Real remove(): an empty pkg_list exits with the BARE
      # exit_json(changed=False) - no msg, no stdout, no cache keys
      # (round-99500x apt_absent_noop capture: {"changed": false};
      # re-verified live against ansible-core 2.19.11, whose registered
      # result carries only `changed` plus the controller's own `failed`).
      # That m.exit_json() fires from INSIDE remove(), before main() gets
      # to assign cache_updated/cache_update_time onto the retvals - so
      # the engine-wide backfill in #execute must be suppressed here too,
      # or the key order comes out as [changed, cache_updated] where real
      # emits [changed].
      if to_remove.empty?
        @omit_cache_updated = true
        return PluginResult.new(changed: false, failed: false, key_order: ["changed"])
      end

      # Real remove()'s spec quoting: plain Python "'%s'" wrapping over
      # the raw specs (pin included).
      pkg_list = to_remove.map { |pkg| naive_single_quote(pkg) }.join(" ")

      # Real remove()'s EXACT command format: "%s -q -y %s %s %s %s %s
      # %s remove %s" over (APT_GET_CMD, dpkg_options, purge, force_yes,
      # autoremove, check_arg, allow_change_held_packages, packages) -
      # empty flag fields keep their separators, and the command RUNS in
      # check mode too (with --simulate), its output becoming the
      # registered stdout (round-99500x apt_check_remove capture). The
      # `apt-get remove` lock retry and policy-rc.d lifecycle wrap mirror
      # the install path.
      flags = [
        real_dpkg_options(lock_timeout),
        @purge ? "--purge" : "",
        @force ? "--force-yes" : "",
        true?(@params["autoremove"]?) ? "--auto-remove" : "",
        @check_mode ? "--simulate" : "",
        @allow_change_held_packages ? "--allow-change-held-packages" : "",
      ]
      remove_cmd = "#{apt_get_bin} -q -y #{flags.join(" ")} remove #{pkg_list}"
      remove_result = with_policy_rc_d { apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive #{remove_cmd}", lock_timeout, ->remote_exec(String)) }
      if remove_result[:exit_code] != 0
        # Real remove() failure: fail_json(msg="'apt-get remove %s'
        # failed: %s" % (packages, err), stdout=out, stderr=err, rc=rc)
        # - the msg quotes "apt-get remove" plus the quoted package
        # list, NOT the full command, and the remove path never gains
        # the cache keys (round-99500x apt_fail_remove_dpkgopt capture:
        # [stdout, stderr, rc, failed, msg, stdout_lines, stderr_lines,
        # changed, exception]).
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "'apt-get remove #{pkg_list}' failed: #{remove_result[:stderr]}",
          stdout: remove_result[:stdout],
          stderr: remove_result[:stderr],
          rc: remove_result[:exit_code],
          key_order: ["stdout", "stderr", "rc", "failed", "msg", "stdout_lines", "stderr_lines"]
        )
      end

      # Real remove() success: exit_json(changed=True, stdout=out,
      # stderr=err, diff=diff) - changed unconditionally true once
      # apt-get ran, no msg key at all, diff only in diff mode
      # (round-99500x captures).
      PluginResult.new(
        changed: true,
        failed: false,
        stdout: remove_result[:stdout],
        stderr: remove_result[:stderr],
        diff: @diff_mode ? apt_install_diff(remove_result[:stdout]) : JSON.parse("{}"),
        key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"]
      )
    end

    # `name: "*"` + `state: latest` - Ansible's apt.py builds
    # EXACTLY the same command as `upgrade: yes` here (its own
    # `upgrade(module, 'yes', ...)` call in the `if latest and
    # all_installed:` branch), never a per-package `apt-get install`.
    # This plugin previously let `packages == ["*"]` fall straight into
    # `handle_latest`, which joins the package list into
    # `apt-get install -y ... *` - apt-get treats a bare `*` as a glob
    # over EVERY package name in the archive (not just already-installed
    # ones), so on a host with a held/conflicting package pair (e.g.
    # jtreg6 held vs. jtreg7 available) it tries to pull in packages a
    # real `apt-get upgrade` never touches (upgrade only touches
    # packages that don't require installing/removing others) and fails
    # outright with "you have held broken packages" where Ansible
    # reports a clean upgrade. Found via MonolithProjects.system_update's
    # own "Update Debian/Ubuntu system" task (round 601048).
    private def handle_wildcard_latest(messages : Array(String), autoremove : Bool, lock_timeout : Int32) : PluginResult
      # Same real-upgrade() command shape as the `upgrade:` block above
      # (identical format string, `upgrade --with-new-pkgs <autoremove>`
      # upgrade_command included).
      upgrade_command = "upgrade --with-new-pkgs #{autoremove ? "--auto-remove" : ""}"
      cmd = "#{apt_get_bin} -y #{real_dpkg_options(lock_timeout)} #{@force ? "--force-yes" : ""} #{@fail_on_autoremove ? "--no-remove" : ""} #{@allow_unauthenticated ? "--allow-unauthenticated" : ""} #{@allow_downgrade ? "--allow-downgrades" : ""} #{@check_mode ? "--simulate" : ""} #{upgrade_command}"
      cmd += " -t #{naive_single_quote(@default_release.not_nil!)}" if @default_release

      result = with_policy_rc_d { apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive #{cmd}", lock_timeout, ->remote_exec(String)) }
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "'#{apt_get_bin} #{upgrade_command}' failed: #{result[:stderr]}",
          stdout: result[:stdout],
          rc: result[:exit_code],
          key_order: ["stdout", "rc", "failed", "msg"]
        )
      end

      # Same APT_GET_ZERO screenscrape as the `upgrade:` command path
      # above - a leading-newline match so a summary whose upgraded
      # count ends in 0 ("10 upgraded, 0 newly installed, 0 to remove")
      # doesn't false-match at an inner offset.
      zero_effect = result[:stdout].includes?("\n0 upgraded, 0 newly installed, 0 to remove")
      messages << result[:stdout]
      # Real apt.py's upgrade(): exit_json(changed=True, msg=out,
      # stdout=out, stderr=err, diff=diff) or its APT_GET_ZERO no-effect
      # exit without diff (round-99500x captures).
      PluginResult.new(
        changed: !zero_effect,
        failed: false,
        msg: messages.join(", "),
        stdout: result[:stdout],
        stderr: result[:stderr],
        diff: zero_effect ? nil : apt_install_diff(result[:stdout]),
        key_order: zero_effect ? ["changed", "msg", "stdout", "stderr", "stdout_lines", "stderr_lines"] : ["changed", "msg", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"]
      )
    end

    # Handle upgrading packages to latest
    private def handle_latest(packages : Array(String), messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      # Same empty-name hard failure Ansible's apt module produces
      # for state: latest as for state: present (live-verified, see
      # handle_install's guard) - only handle_remove's absent path
      # tolerates one.
      if packages.any?(&.empty?)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "No package matching '' is available"
        )
      end

      # only_upgrade: Ansible's install() skips packages that are
      # not installed at all when only_upgrade is set (`if not installed
      # and only_upgrade: continue` - only upgrades, never newly
      # installs), for state: latest the same as for state: present.
      if @only_upgrade
        installed_status = dpkg_installed_status(packages)
        packages = packages.select do |pkg|
          base_name, _ = split_name_version(pkg)
          installed_status[base_name]?.try(&.[0]) || false
        end
        if packages.empty?
          messages << "No packages upgraded (only_upgrade skips packages that are not installed)"
          return PluginResult.new(changed: false, failed: false, msg: messages.join(", "))
        end
      end

      if @check_mode
        # `grep -i upgrade` matched the ALWAYS-present "N upgraded, M newly
        # installed" summary line of simulate output, so check mode never
        # converged to ok. `^Inst` only matches an actual install/upgrade
        # action line.
        check_cmds = packages.map { |pkg| "apt-get install --simulate #{shell_single_quote(pkg)} 2>&1 | grep '^Inst'" }
        check_result = remote_exec(check_cmds.join(" || "))
        if check_result[:exit_code] == 0
          messages << "Would upgrade #{packages.join(", ")} to latest"
          changed = true
        else
          messages << "Package#{packages.size > 1 ? "s" : ""} #{packages.join(", ")} already at latest version"
        end
      else
        # `--only-upgrade` skips a package that isn't ALREADY installed
        # entirely ("Skipping grafana, it is not installed and only
        # upgrades are requested" - exit 0, "0 upgraded, 0 newly
        # installed") - Ansible's own state: latest installs a
        # not-yet-present package too (apt-get's plain `install` already
        # does both: fresh-install when absent, upgrade when present and
        # outdated), so this plugin's own `--only-upgrade` flag was
        # simply wrong. Real bug found benchmarking cloudalchemy.
        # grafana's own "Install Grafana" task (state: "{{ (grafana_
        # version == 'latest') | ternary('latest', 'present') }}") -
        # reported "changed: Package grafana upgraded to latest" while
        # the package was never actually installed at all.
        # `state: latest` (apt-get install for upgrade-or-install)
        # contends for the dpkg lock - wrap with lock_timeout retry,
        # plus the same implicit cache-update retry on corrupt/
        # unparseable lists that handle_install above gets. The
        # dpkg_options:/only_upgrade:/force:/fail_on_autoremove: flags,
        # the -t <default_release> and the -o APT::Install-Recommends=...
        # / --allow-* flags all mirror Ansible's install() command
        # construction (state: latest flows through install() there
        # with upgrade=True), inside the policy-rc.d lifecycle.
        # Ansible's state=latest routes through the SAME install() as
        # state=present (apt.py main(): `state_upgrade = True` for
        # latest, then one install() call), so the command is Ansible's
        # install() shape verbatim - `-y <dpkg_options> <only_upgrade>
        # install <specs><trailing>` with the lock-timeout-augmented
        # dpkg_options and the resolved candidate pinned onto each spec
        # (live-verified: `apt-get -y -o Dpkg::Options::=--force-confdef
        # -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=60
        # install tree=2.0.2-1`). The plugin previously built its own
        # `apt-get install -y <opts> <flags> <name>` line, which no real
        # capture or apt.py format string produces.
        spec_list = packages.map do |pkg|
          base_name, pinned_version = split_name_version(pkg)
          _resolvable, candidate = apt_candidate(base_name)
          version = pinned_version || candidate
          version ? "#{base_name}=#{version}" : base_name
        end
        pkg_list = spec_list.map { |spec| naive_single_quote(spec) }.join(" ")
        flags = [
          real_dpkg_options(lock_timeout),
          @only_upgrade ? "--only-upgrade" : "",
          @force ? "--force-yes" : "",
          true?(@params["autoremove"]?) ? "--auto-remove" : "",
          @fail_on_autoremove ? "--no-remove" : "",
        ]
        latest_cmd = "#{apt_get_bin} -y #{flags.join(" ")} install #{pkg_list}#{apt_install_trailing_flags}"
        upgrade_result = with_policy_rc_d { apt_install_with_implicit_cache_retry(latest_cmd, lock_timeout, ->remote_exec(String)) }

        # apt-get exits 100 when a package can't be located at all
        # ("E: Unable to locate package sensu" - e.g. a repo that carries
        # no candidate for this release). That's a hard failure the way
        # Ansible's apt module fails with "No package matching X is
        # available", NOT a clean "already at latest" - the previous code
        # fell through to success here (found via buluma.sensu-install,
        # where packagecloud's sensu/stable repo has no jammy candidate).
        if upgrade_result[:exit_code] != 0
          return PluginResult.new(
            changed: changed,
            failed: true,
            msg: "Failed to install latest: #{upgrade_result[:stderr]}"
          )
        end

        # "N upgraded, M newly installed, ..." is apt's own reliable,
        # locale-stable summary line - checking for the English phrase
        # "already the newest version" (the previous approach) missed
        # the "not installed and only upgrades are requested" case
        # entirely (a different message, so the check wrongly concluded
        # something HAD changed).
        summary = upgrade_result[:stdout][/(\d+) upgraded, (\d+) newly installed/]?
        was_upgraded = summary ? summary.scan(/\d+/).sum(&.[0].to_i) > 0 : upgrade_result[:exit_code] == 0
        if was_upgraded
          messages << "Package#{packages.size > 1 ? "s" : ""} #{packages.join(", ")} upgraded to latest"
          changed = true
        else
          messages << "Package#{packages.size > 1 ? "s" : ""} #{packages.join(", ")} already at latest version"
        end
      end

      msg = messages.empty? ? "No changes needed" : messages.join(", ")
      if @check_mode && changed
        msg += " (check mode)"
      end

      # Real apt.py's state=latest flows through install() (its retvals
      # shape - live-verified against Ansible 2.19.11: changed installs
      # carry stdout/stderr/diff + the cache keys, unchanged reruns the
      # cache keys only).
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        key_order: ["changed", "stdout", "stderr", "diff", "cache_updated", "cache_update_time", "stdout_lines", "stderr_lines"]
      )
    end

    # Ansible's expand_dpkg_options (apt.py): the comma-separated
    # `dpkg_options:` list, each option becoming its own
    # `-o Dpkg::Options::=--<option>` flag. Default
    # "force-confdef,force-confold" reproduces the pair this plugin
    # hardcoded before the param existed.
    private def expand_dpkg_options : String
      @dpkg_options.split(",").map(&.strip).reject(&.empty?)
        .map { |opt| "-o Dpkg::Options::=--#{opt}" }.join(" ")
    end

    # Real main()'s dpkg_options value - expand_dpkg_options' output
    # (with REAL's double-quoted -o values, not the unquoted form
    # #expand_dpkg_options builds) plus the lock-timeout override it
    # appends: `-o "Dpkg::Options::=--force-confdef" -o
    # "Dpkg::Options::=--force-confold" -o DPkg::Lock::Timeout=60`. The
    # exact text is quoted verbatim inside Ansible's "'cmd' failed" failure
    # msg, so the quoting is load-bearing.
    private def real_dpkg_options(lock_timeout : Int32) : String
      opts = @dpkg_options.split(",").map(&.strip).reject(&.empty?)
        .map { |opt| "-o \"Dpkg::Options::=--#{opt}\"" }.join(" ")
      "#{opts} -o DPkg::Lock::Timeout=#{lock_timeout}"
    end

    # Real apt.py quotes package specs and -t releases with plain Python
    # "'%s'" formatting - no shell escaping at all. Reproduced verbatim,
    # since the quoted text is part of the registered failure msgs.
    private def naive_single_quote(value : String) : String
      "'#{value}'"
    end

    # Real apt.py's APT_GET_CMD: get_bin_path("apt-get") - the RESOLVED
    # absolute path ("/usr/bin/apt-get" in the captures), which is what
    # the "'cmd' failed" failure msgs quote. Resolved through the remote
    # PATH the same way; falls back to the bare name when not found (the
    # /usr/bin/apt-get existence guard above already covered the
    # non-Debian case).
    private def apt_get_bin : String
      @apt_get_bin ||= begin
        probe = remote_exec("command -v apt-get")
        path = probe[:stdout].strip
        path.empty? ? "apt-get" : path
      end
    end

    # The flags Ansible's install() places BEFORE the package list
    # (apt.py cmd construction: only_upgrade, fixed, force_yes,
    # fail_on_autoremove all precede `install`). `fixed` has no module
    # param (state: fixed is a separate state this plugin doesn't offer
    # yet), so only three of the four slots can ever fire here.
    private def apt_install_leading_flags : String
      flags = [] of String
      flags << "--only-upgrade" if @only_upgrade
      flags << "--force-yes" if @force
      flags << "--no-remove" if @fail_on_autoremove
      flags.empty? ? "" : " " + flags.join(" ")
    end

    # The options Ansible's install() appends AFTER the package
    # list, in its own construction order: -t <default_release> (skipped
    # when include_default_release is false - install_deb()'s dependency
    # pre-install call passes install() no default_release, so even a
    # `default_release:` task param must not leak a -t into it), the
    # APT::Install-Recommends override (only when install_recommends: is
    # explicitly set - nil keeps apt's own default), then the three
    # --allow-* flags.
    private def apt_install_trailing_flags(include_default_release : Bool = true) : String
      flags = [] of String
      if include_default_release && (release = @default_release)
        flags << "-t #{shell_single_quote(release)}"
      end
      # `!= nil` (not a bare truthiness check) - false is falsy in
      # Crystal but is exactly the case that must emit the =no override.
      if (ir = @install_recommends) != nil
        flags << (ir ? "-o APT::Install-Recommends=yes" : "-o APT::Install-Recommends=no")
      end
      flags << "--allow-unauthenticated" if @allow_unauthenticated
      flags << "--allow-downgrades" if @allow_downgrade
      flags << "--allow-change-held-packages" if @allow_change_held_packages
      flags.empty? ? "" : " " + flags.join(" ")
    end

    # The flags Ansible's upgrade() places before the upgrade
    # subcommand (force_yes, fail_on_autoremove, allow_unauthenticated,
    # allow_downgrades - upgrade() takes no only_upgrade/
    # install_recommends/allow_change_held_packages, matching above).
    private def apt_upgrade_flags : String
      flags = [] of String
      flags << "--force-yes" if @force
      flags << "--no-remove" if @fail_on_autoremove
      flags << "--allow-unauthenticated" if @allow_unauthenticated
      flags << "--allow-downgrades" if @allow_downgrade
      flags.empty? ? "" : " " + flags.join(" ")
    end

    # upgrade()'s trailing `-t <default_release>` (the only trailing
    # option upgrade() appends).
    private def upgrade_trailing_flags : String
      release = @default_release ? " -t #{shell_single_quote(@default_release.not_nil!)}" : ""
      release
    end

    # Ansible's PolicyRcD context manager (apt.py): when
    # `policy_rc_d:` is non-null, back up any existing /usr/sbin/
    # policy-rc.d, write one that always exits with the given code (the
    # file dpkg's package maintainer scripts consult via invoke-rc.d to
    # decide whether to (re)start services on install), run the apt
    # operation inside that window, then restore the backup - or remove
    # the written file when none existed - ALWAYS, including when the
    # operation failed. Every package-operation command Ansible
    # runs (install/remove/cleanup/upgrade/deb) gets its own
    # PolicyRcD window; the cache update does not, matching here (only
    # the handle_*/cleanup call sites below are wrapped). Restore
    # failure fails the task the way __exit__'s own fail_json does.
    # The result shape every apt command helper (apt_with_lock_retry,
    # apt_install_with_implicit_cache_retry) returns.
    private def with_policy_rc_d(& : -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      return yield if (desired_rc = @policy_rc_d).nil?

      path = @policy_rc_d_path
      backup_path = "#{path}.krikri-backup.#{Random.rand(1_000_000)}"
      had_existing = remote_exec("test -e #{shell_single_quote(path)}")[:exit_code] == 0

      if had_existing
        move = remote_exec("mv #{shell_single_quote(path)} #{shell_single_quote(backup_path)}")
        if move[:exit_code] != 0
          return {exit_code: 1, stdout: "", stderr: "Fail to move #{path} to #{backup_path}: #{move[:stderr]}"}
        end
      end

      write = remote_exec("printf '#!/bin/sh\\nexit #{desired_rc}\\n' > #{shell_single_quote(path)} && chmod 0755 #{shell_single_quote(path)}")
      if write[:exit_code] != 0
        restore_policy_rc_d(had_existing, backup_path)
        return {exit_code: 1, stdout: "", stderr: "Failed to create or chmod #{path}: #{write[:stderr]}"}
      end

      @policy_rc_d_restore_failed = false
      inner = begin
        yield
      ensure
        @policy_rc_d_restore_failed = !restore_policy_rc_d(had_existing, backup_path)
      end

      # Restore failure fails the task even when the operation itself
      # succeeded - Ansible's __exit__ fail_json's the same way.
      # When the operation already failed its own error surfaces
      # instead (the task fails either way).
      if @policy_rc_d_restore_failed && inner[:exit_code] == 0
        inner = {exit_code: 1, stdout: inner[:stdout], stderr: "Fail to move back #{backup_path} to #{path} (or remove the temporary policy-rc.d)"}
      end

      inner
    end

    private def restore_policy_rc_d(had_existing : Bool, backup_path : String) : Bool
      if had_existing
        remote_exec("mv #{shell_single_quote(backup_path)} #{shell_single_quote(@policy_rc_d_path)}")[:exit_code] == 0
      else
        remote_exec("rm -f #{shell_single_quote(@policy_rc_d_path)}")[:exit_code] == 0
      end
    end

    # Shared tail of both cache-update branches (python3-apt present and
    # the respawn-emulation fallback): routes an `apt-get update` result
    # to the failure shape it maps to in real apt.py. A failed-fetch
    # result (python-apt's bare FetchFailedException - the CLI's exit-0
    # W:-lines output, or a nonzero exit that is not lock contention)
    # goes through apt.py's own FetchFailedException retry loop and, once
    # the update_cache_retries budget is exhausted, fails with its exact
    # wording and the warn-pair warnings (round 1100002 kop_apt_fail
    # apt_fail_bogus_source: krikri trusted the CLI's exit 0 and reported
    # changed=true where Ansible fails). Lock-contention and other
    # nonzero exits keep the previous "Failed to update apt cache:"
    # shape. Returns nil when the update succeeded or was recovered by a
    # retry attempt - the caller then proceeds to its normal post-update
    # mtime bookkeeping.
    private def settle_update_cache_failure(update_result : NamedTuple(exit_code: Int32, stdout: String, stderr: String), update_cache_retries : Int32, update_cache_retry_max_delay : Int32) : PluginResult?
      fetch_failed = apt_fetch_failed?(update_result) &&
                     (update_result[:exit_code] == 0 || !apt_lock_held?(update_result[:stderr]))
      if fetch_failed
        outcome = apt_fetch_failed_update_retry(update_cache_retries, update_cache_retry_max_delay, ->remote_exec(String))
        return nil if outcome[:recovered]
        # a fail_json exit carries no cache keys (the retvals assignment
        # in main() never runs) - suppress the engine-wide backfill
        @omit_cache_updated = true
        result = PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to update apt cache after #{update_cache_retries} retries: #{outcome[:warnings].empty? ? "unknown reason" : ""}",
        )
        result.extra["warnings"] = JSON.parse(outcome[:warnings].to_json) unless outcome[:warnings].empty?
        return result
      end
      if update_result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to update apt cache: #{update_result[:stderr]}"
        )
      end
      nil
    end

    # Check if cache should be updated based on validity time
    private def should_update_cache?(cache_valid_time : Int32) : Bool
      return true if cache_valid_time == 0

      # Ansible's apt.py checks /var/lib/apt/periodic/update-success-
      # stamp's mtime if present (written by APT::Periodic's own update
      # timer/unattended-upgrades), else falls back to the /var/lib/apt/
      # lists DIRECTORY's own mtime. This previously stat'd /var/lib/apt/
      # lists/partial instead - a transient staging dir apt-get update
      # barely touches, not a real freshness signal - so its mtime stayed
      # old (image-build time) and `age > cache_valid_time` was almost
      # always true, refreshing (and reporting changed: true for) a cache
      # Ansible correctly saw as still valid and left alone. Found
      # benchmarking Stouts.apt's own "Update apt cache" task (default
      # apt_cache_valid_time: 3600) - py reported `ok`, cr `changed`.
      last_update = cache_mtime
      current_time = Time.utc.to_unix

      age = current_time - last_update
      age > cache_valid_time
    end

    # Thin wrappers over AptLockRetry's own shared `apt_cache_mtime`/
    # `apt_python_apt_present?` (see there) - kept here, at the same
    # names/signatures every call site above already used, so this is
    # the only file that changed when the logic moved to the shared
    # module. One implementation now backs both this plugin and
    # package.cr's own cache-refresh-only path - see AptLockRetry's own
    # comment for why that single-source-of-truth matters (this exact
    # class of duplicate-implementation drift is what caused
    # robertdebock.update_package_cache's regression).
    private def cache_mtime : Int32
      apt_cache_mtime(->remote_exec(String))
    end

    private def python_apt_present? : Bool
      apt_python_apt_present?(->remote_exec(String))
    end

    # Helper to convert string/bool to boolean
    # The lock-contention retry helpers (apt_with_lock_retry,
    # apt_get_update_with_retry, apt_lock_held?) live in
    # `src/krikri/plugin_helpers/apt_lock_retry.cr` and are
    # mixed in via `include AptLockRetry` at the top of this class -
    # one canonical implementation, exercised by the regression spec
    # without needing the plugin's entry point.
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::AptPlugin.new(config)
plugin.run

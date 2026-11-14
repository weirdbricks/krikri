#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/ansible_splitlines"
require "../src/krikri/plugin_helpers/apt_lock_retry"
require "../src/krikri/plugin_helpers/apt_deb_install"
require "../src/krikri/plugin_helpers/apt_locale"

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
  #   force_apt_get (steers backend selection: real apt.py prefers
  #   aptitude for safe/yes/full upgrades whenever aptitude is installed,
  #   and force_apt_get is what pins it back onto apt-get - see
  #   run_upgrade_backend),
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
    include AptDebInstall
    include AptLocale
    include PluginHelpers::AnsibleArgValidation

    # See AptDebInstall#deb_suppress_cache_backfill! - the apt plugin owns
    # the cache-key backfill, so the deb: path suppresses it here.
    private def deb_suppress_cache_backfill! : Nil
      @omit_cache_updated = true
    end

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

    # This plugin's underscore-prefixed spec seams (same family as
    # apt_repository.cr's own `_apt_get_paths`/`_sources_list`): never
    # set by real playbooks (Ansible has no such params and would reject
    # them), only by the specs, which need to drive the no-apt-get,
    # python3-apt-absent and aptitude-backend paths on a dev box that
    # really has (or lacks) the real binaries.
    private SPEC_SEAMS = {"_policy_rc_d_path", "_apt_get_paths", "_python_apt_absent", "_aptitude_paths"}

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
    @aptitude_bin : String? = nil
    @apt_mark_bin : String? = nil
    @policy_rc_d : Int32? = nil
    @purge = false
    @force = false
    @force_apt_get = false
    @fail_on_autoremove = false
    @only_upgrade = false
    @allow_unauthenticated = false
    @allow_downgrade = false
    @allow_change_held_packages = false
    @default_release : String? = nil
    @install_recommends : Bool? = nil
    @policy_rc_d_restore_failed = false

    # Real apt.py's module-wide run_command_environ_update (see the
    # AptLocale helper): probed once per invocation like Ansible's
    # get_best_parsable_locale, then reused by every apt command below.
    @apt_env_prefix : String? = nil

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
      result.extra["cache_updated"] = JSON.parse(@cache_updated.to_json) unless result.extra.has_key?("_ansible_error_detail") || @omit_cache_updated || result.msg.to_s.starts_with?("No package matching") || result.msg.to_s.starts_with?("No package(s) matching")
      result
    end

    private def apt_environment_prefix : String
      prefix = @apt_env_prefix
      prefix ||= apt_env_prefix { |cmd| remote_exec(cmd) }
      @apt_env_prefix = prefix
      prefix
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
      # and _policy_rc_d_path/_apt_get_paths/_python_apt_absent are this
      # plugin's own spec seams (SPEC_SEAMS above) - none are part of
      # Ansible's argument_spec, so none are rejected. (The seams need
      # an explicit exemption: they are not in the shared INTERNAL
      # list because they are this plugin's alone, and the
      # policy_rc_d lifecycle specs pass _policy_rc_d_path on every call.)
      # Ansible collects unsupported params but reports them LAST in its
      # check order (mutually_exclusive -> ... -> unsupported), so the
      # mutually-exclusive/choices/bool checks below all beat a typo'd
      # parameter (see dnf.cr).
      unsupported = unsupported_param_keys(@params, APT_SPEC).reject { |key| SPEC_SEAMS.includes?(key) }
      unsupported_rejection : PluginResult? = nil
      unless unsupported.empty?
        unsupported_rejection = unsupported_params_error(
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

      # unsupported-params is reported only after every other spec check
      return unsupported_rejection if unsupported_rejection

      # The refusal is module-start-wide, not cache-flag-gated: real
      # apt.py cannot even begin when the bindings are missing and it
      # is in check mode, so a plain name install fails there too
      # (check mode's only recovery would be the auto-install, which
      # is a real host mutation). It must be evaluated BEFORE the
      # no-apt-get guard below: apt.py's !HAVE_PYTHON_APT ladder fails
      # with this refusal before it ever attempts the auto-install, so
      # even on a host with no apt-get at all the check-mode task dies
      # here and never reaches the auto-install whose ENOENT the guard
      # mirrors (issue #1034: ajilraju.apache2 on Rocky - ansible
      # reported this message where this engine reported the guard's
      # "Error executing command" shape plus the auto-install warning).
      if @check_mode && !python_apt_present?
        return check_mode_no_python_apt_result
      end

      # Ansible's apt module on a non-Debian-family host: it first
      # auto-installs its python3-apt dependency ("Updating cache and
      # auto-installing missing dependency: python3-apt" warning) via
      # AnsibleModule.run_command, which fails ENOENT with exactly
      # {"changed": false, "cmd": "update", "msg": "Error executing
      # command.", "rc": 2} - observed live on Rocky 9.6 with Oefenweb.dns
      # (round 196). Without this guard this engine's dpkg-query-based
      # absent path quietly reported "Package ... not installed" rc=0.
      # Check mode must never reach that attempt: real's !HAVE_PYTHON_APT
      # ladder fails fast with the python3-apt refusal instead (the
      # module-start check above), because the auto-install is a real
      # host mutation - so this ENOENT shape is a NORMAL-run-only
      # outcome (issues #1033/#1034, agx.gbp and ajilraju.apache2 on
      # Rocky: ansible's --check output for these tasks is the bare
      # refusal, where this guard used to answer with the shape below).
      # The module-start refusal fires first on bindings-less hosts;
      # the @check_mode skip here also keeps this shape out of check
      # output in the exotic bindings-present case, where the
      # auto-install (whose failure this mirrors) would never run.
      unless @check_mode || apt_get_paths.any? { |path| File.exists?(path) }
        # apt.py's `module.params.get('update_cache') is False` branch
        # (a task passing update_cache: no, e.g. timstaley.base's
        # "Ensure aptitude installed" task, issue #1172) never reaches
        # the update prefetch: it warns the OTHER variant, "Auto-
        # installing missing dependency without updating cache", and
        # goes straight to the install attempt - whose None binary
        # (no apt-get resolved on the host) run_command silently DROPS
        # (basic.py's `if x is not None` filter), so argv[0] becomes
        # 'install' and coreutils' install executes via PATH and dies
        # on the unknown -y flag: rc 1, "install: invalid option --
        # 'y'" (observed live on Rocky 9.6, round29908315). Run the
        # same command so the host's own coreutils produces the exact
        # stderr, and shape the failure like run_command's check_rc
        # fail_json: msg = stderr.rstrip, cmd = the shlex-quoted
        # _clean_args string, the raw rc - and NO exception detail,
        # unlike the prefetch-ENOENT branch below, because a command
        # that RAN fails with check_rc's msg/stderr shape, not the
        # OSError handler's (the [ERROR] block quotes the module msg
        # itself in the same round's capture).
        explicitly_no_cache = @params["update_cache"]? ? !true?(@params["update_cache"]?) : false
        if explicitly_no_cache
          @dpkg_options = @params["dpkg_options"]? || "force-confdef,force-confold"
          # The dpkg options ride as ONE argv element in apt.py's
          # apt_pkg_cmd list (expand_dpkg_options + lock timeout, real's
          # double-quoted -o values), so both the executed shell word and
          # the reported cmd quote it as a single argument.
          dpkg_element = real_dpkg_options(@params["lock_timeout"]?.try(&.to_i) || 60)
          recommends_arg = if ir = @params["install_recommends"]?
                             true?(ir) ? " -o APT::Install-Recommends=yes" : " -o APT::Install-Recommends=no"
                           else
                             ""
                           end
          cmd_string = "install python3-apt -y -q #{shell_single_quote(dpkg_element)}#{recommends_arg}"
          warning = "Auto-installing missing dependency without updating cache: python3-apt"
          @omit_cache_updated = true
          # A host whose PATH has no `install` either (busybox-only
          # images) never gets a process running at all, so the OSError
          # handler - not check_rc - shapes the failure: the exact
          # prefetch-ENOENT shape below but with argv[0]='install' as the
          # failed exec name (b'install' in the [ERROR] block).
          if remote_exec("command -v install")[:exit_code] != 0
            result = PluginResult.new(
              changed: false,
              failed: true,
              msg: "Error executing command.",
              cmd: cmd_string,
              rc: 2,
              stdout: "",
              stderr: "",
              stdout_lines: [] of String,
              stderr_lines: [] of String,
              key_order: ["changed", "cmd", "msg", "rc", "stderr", "stderr_lines", "stdout", "stdout_lines"],
              _ansible_error_detail: "Error executing command: [Errno 2] No such file or directory: b'install'"
            )
            result.extra["warnings"] = JSON.parse([warning].to_json)
            return result
          end
          # real runs the attempt under APT_ENV_VARS
          # (run_command_environ_update, set at main() start), whose
          # locale is always an English one - riding the same prefix keeps
          # the host's coreutils stderr byte-stable where an sshd-forwarded
          # LANG would translate it away from real's output. The reported
          # cmd stays the bare _clean_args string; env never rides in it.
          cmd_result = remote_exec("#{apt_environment_prefix} #{cmd_string}")
          result = PluginResult.new(
            changed: false,
            failed: true,
            msg: cmd_result[:stderr].rstrip,
            cmd: cmd_string,
            rc: cmd_result[:exit_code],
            stdout: cmd_result[:stdout],
            stderr: cmd_result[:stderr],
            stdout_lines: cmd_result[:stdout].lines,
            stderr_lines: cmd_result[:stderr].lines,
            key_order: ["changed", "cmd", "msg", "rc", "stderr", "stderr_lines", "stdout", "stdout_lines"]
          )
          result.extra["warnings"] = JSON.parse([warning].to_json)
          return result
        end
        # Real run_command's ENOENT shape keeps the bare "Error executing
        # command." as the fatal msg while the [ERROR] block renders the
        # Errno text from the exception field - here carried as
        # _ansible_error_detail like the APT::Default-Release exit below
        # (live-verified vs 2.19.11, round 196 / issue #18: "Task failed:
        # Module failed: Error executing command: [Errno 2] No such file
        # or directory: b'update'"). The fail_json dict carries empty
        # stdout/stderr(+_lines), no cache keys, and its keys dump sorted;
        # the module warns about the python3-apt auto-install it was
        # attempting before failing.
        @omit_cache_updated = true
        result = PluginResult.new(
          changed: false,
          failed: true,
          msg: "Error executing command.",
          cmd: "update",
          rc: 2,
          stdout: "",
          stderr: "",
          stdout_lines: [] of String,
          stderr_lines: [] of String,
          key_order: ["changed", "cmd", "msg", "rc", "stderr", "stderr_lines", "stdout", "stdout_lines"],
          _ansible_error_detail: "Error executing command: [Errno 2] No such file or directory: b'update'"
        )
        result.extra["warnings"] = JSON.parse(["Updating cache and auto-installing missing dependency: python3-apt"].to_json)
        return result
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
      # fast in check mode instead (refusal mirrored at module start
      # above).
      unless @check_mode
        explicitly_no_cache = @params["update_cache"]? ? !true?(@params["update_cache"]?) : false
        if failure = apt_auto_install_python_apt(explicitly_no_cache, ->remote_exec(String), force_absent: true?(@params["_python_apt_absent"]?), vars: @vars)
          # Real ansible's fail_json for the failed auto-install stage
          # carries the RAW command result (msg = stderr.rstrip, no custom
          # prefix) with NO cache_updated key - the module never got to
          # touch the cache - plus the warning it emitted before
          # attempting the install (issue #522).
          @omit_cache_updated = true
          return apt_auto_install_failure_result(failure)
        end
      end

      # 2.21's get_cache tail (live-verified vs 2.21.6's apt.py): when
      # the apt lists directory is absent the cache is recreated with
      # `apt-get update -q` (up to two tries) and a still-failing run
      # fails the task with exactly this message; 2.19 only recovered
      # when python-apt itself raised on the lists path. Runs in check
      # mode too (module-level get_cache precedes every branch).
      unless Dir.exists?("/var/lib/apt/lists")
        rc, stdout, stderr = recreate_apt_cache
        if rc != 0
          @omit_cache_updated = true
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to recreate the cache: #{stdout + stderr}",
            rc: rc.to_i64,
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
      # expand_dpkg_options). `auto_install_module_deps` is a documented
      # no-op here; `force_apt_get` is load-bearing for upgrade modes -
      # it is what keeps real apt.py on apt-get instead of aptitude.
      @force_apt_get = true?(@params["force_apt_get"]?)
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

      @default_release = @params["default_release"]?
      if ir = @params["install_recommends"]?
        @install_recommends = true?(ir)
      end

      changed = false
      messages = [] of String

      # aptclean() is apt.py's FIRST branch: `apt-get clean` runs - and,
      # when no package/upgrade/deb was requested, immediately exits
      # changed=True on aptclean's own result - before the package cache
      # is ever opened. That means APT::Default-Release is never set for
      # such a task (an unknown default_release: goes unvalidated) and the
      # update_cache pass never runs. Both orderings are observable: with
      # clean: true + update_cache: true + an unknown default_release:,
      # real Ansible reported changed without touching the lists, while
      # this engine failed the task with python-apt's invalid-release
      # error (issue #1265).
      if clean
        clean_result = if @check_mode
                         messages << "Would run: apt-get clean"
                         {exit_code: 0, stdout: "", stderr: ""}
                       else
                         # `apt-get clean` contends for the dpkg lock
                         # like every other apt-get op - same lock_timeout
                         # retry + PolicyRcD wrap as the cleanup() ops
                         # below. aptclean() runs the bare command, with
                         # no dpkg options at all.
                         res = with_policy_rc_d { apt_with_lock_retry("apt-get clean", lock_timeout, ->remote_exec(String)) }
                         if res[:exit_code] != 0
                           return PluginResult.new(changed: false, failed: true, msg: "apt-get clean failed: #{res[:stderr]}")
                         end
                         messages << "cache cleaned"
                         res
                       end
        # aptclean()'s own result is discardable when the module keeps
        # running (a package install's exit_json overwrites it) - its
        # changed: only matters through this early exit, which is
        # UNCONDITIONAL (`not p['package'] and p['upgrade'] == 'no' and
        # not p['deb']`), not output-matched (exit_json(changed=True,
        # msg=<clean stdout>, stdout=..., stderr=..., diff=...) - an empty
        # clean output still carries its empty msg key, include_empty_msg).
        changed = true
        if cache_update_is_sole_operation
          # aptclean()'s exit carries NO cache keys (its exit_json never
          # saw the cache pass) - suppress the engine's cache_updated
          # backfill the same way the deb path does.
          @omit_cache_updated = true
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: @check_mode ? messages.join(", ") : clean_result[:stdout],
            stdout: clean_result[:stdout],
            stderr: clean_result[:stderr],
            diff: @diff_mode && !@check_mode ? apt_install_diff(clean_result[:stdout]) : JSON.parse("{}"),
            include_empty_msg: true,
            failed_flag: true,
            key_order: ["changed", "msg", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines", "failed"],
          )
        end
      end

      # python-apt opens the cache with APT::Default-Release set and raises
      # SystemError("E:The value ... is invalid ...") for an unknown release -
      # an unhandled module exception, surfaced as "Task failed: Module failed:"
      # in the fatal msg and the [ERROR] block (live-verified vs 2.19.11).
      # apt.py reaches that cache open only after its `clean:` block, which
      # is main()'s FIRST action and - for a task with no name/upgrade/deb -
      # exit_json()s right there: a clean-only task never evaluates
      # default_release at all (kpg 000034-multi-apt-chaos: real ansible
      # reported `changed` for `clean: true` plus an unknown
      # default_release where this engine failed on the probe below).
      if release = @default_release.presence
        unless clean && cache_update_is_sole_operation
          probe = remote_exec("apt-get -o APT::Default-Release=#{Process.quote(release)} check 2>&1")
          if line = probe[:stdout].lines.find(&.includes?("is invalid for APT::Default-Release"))
            detail = line.strip.sub(/\AE: /, "E:")
            return PluginResult.new(changed: false, failed: true, msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
          end
        end
      end

      # Real apt.py reads the lists-dir mtime unconditionally at the top
      # of its cache pass (get_updated_cache_time()) - not just when an
      # update is due - so an install with no cache flags at all still
      # carries the current mtime as cache_update_time.
      @cache_update_time = cache_mtime

      # Handle cache update
      if update_cache || has_cache_valid_time
        # Belt-and-braces repeat of the module-start refusal above (which
        # already fails every check-mode + missing-bindings task before
        # this point, exactly like apt.py's ladder). On hosts WITH
        # python3-apt nothing changes here.
        if @check_mode && !python_apt_present?
          return check_mode_no_python_apt_result
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
      # (`clean` is NOT part of this guard: aptclean() runs before that
      # dispatch with or without packages and with or without upgrade:,
      # and is handled above, before the cache pass.)
      if (autoremove || autoclean) && !upgrade
        # Ansible's cleanup() builds `apt-get -y <dpkg_options>
        # <purge> <force_yes> <operation> <check_arg>` - the purge/force
        # flags and the dpkg options apply to autoremove/autoclean too
        # (`purge: true` + `autoremove: true` is its own documented
        # idiom: "Remove dependencies that are no longer required and
        # purge their configuration files").
        # Ansible's main() builds its `dpkg_options` ONCE - the
        # expanded list PLUS the lock-timeout override - and passes that
        # same value to cleanup(), install(), remove() and upgrade()
        # alike, so the lock timeout rides along on the cleanup command
        # too (live-verified against ansible-core 2.19.11: `apt-get -y
        # -o Dpkg::Options::=--force-confdef -o
        # Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=60
        # --purge --force-yes autoremove`).
        cleanup_flags = [real_dpkg_options(lock_timeout), (@purge ? "--purge" : nil), (@force ? "--force-yes" : nil)].compact.join(" ")

        # The cleanup operations are EARLY EXITS, not a cleanup pass.
        # main()'s order is aptclean (clean:) -> the update_cache pass ->
        # `if not packages: if autoclean: cleanup(autoclean); if
        # autoremove: cleanup(autoremove)` - and cleanup() calls
        # exit_json() ITSELF the moment its single apt-get op finishes,
        # so at most ONE of the two ever runs per task: with
        # `autoclean: true` AND `autoremove: true` (buluma.os_updates'
        # "Debian | APT autoremove", rounds 952518 + 5460307) real
        # Ansible runs ONLY the autoclean op - packages that have merely
        # become autoremovable stay installed and the task reports
        # autoclean's own 'Del ' marker - while this engine previously
        # ran autoremove too (first, no less) and reported its "The
        # following packages will be REMOVED" marker as the task's
        # changed:. The update_cache pass's own no-packages exit
        # (`cache_update_is_sole_operation`) also sits before the
        # cleanup tail in main(), so a cache-refresh-only run never
        # reaches autoclean/autoremove at all (the no-name tail below
        # returns that exit).
        cache_pass_exits = (update_cache || has_cache_valid_time) && cache_update_is_sole_operation
        if autoclean && no_effective_packages && !cache_pass_exits
          cmd = "#{apt_get_bin} -y#{cleanup_flags.empty? ? "" : " " + cleanup_flags} autoclean"
          # check mode still runs the op - with --simulate, exactly like
          # cleanup()'s check_arg - and marker-checks the simulate
          # output like the real run (a no-op simulate output reports
          # changed: false, not a blanket true).
          cmd += " --simulate" if @check_mode

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
          # true for autoclean specifically. cleanup()'s exit_json is
          # (changed, stdout, stderr, diff) plus the
          # controller-appended stdout_lines/stderr_lines pair and
          # failed: false - NO msg key and NO cache keys at all.
          @omit_cache_updated = true
          return PluginResult.new(
            changed: result[:stdout].includes?("Del "),
            failed: false,
            stdout: result[:stdout],
            stderr: result[:stderr],
            diff: @diff_mode ? apt_install_diff(result[:stdout]) : JSON.parse("{}"),
            stdout_lines: PluginHelpers::AnsibleSplitlines.split(result[:stdout]),
            stderr_lines: PluginHelpers::AnsibleSplitlines.split(result[:stderr]),
            failed_flag: true,
            key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines", "failed"],
          )
        end

        if autoremove && no_effective_packages && !cache_pass_exits
          cmd = "#{apt_get_bin} -y#{cleanup_flags.empty? ? "" : " " + cleanup_flags} autoremove"
          cmd += " --simulate" if @check_mode
          result = with_policy_rc_d { apt_with_lock_retry(cmd, lock_timeout, ->remote_exec(String)) }
          if result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true, msg: "#{cmd} failed: #{result[:stderr]}")
          end
          @omit_cache_updated = true
          return PluginResult.new(
            changed: result[:stdout].includes?("The following packages will be REMOVED"),
            failed: false,
            stdout: result[:stdout],
            stderr: result[:stderr],
            diff: @diff_mode ? apt_install_diff(result[:stdout]) : JSON.parse("{}"),
            stdout_lines: PluginHelpers::AnsibleSplitlines.split(result[:stdout]),
            stderr_lines: PluginHelpers::AnsibleSplitlines.split(result[:stderr]),
            failed_flag: true,
            key_order: ["changed", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines", "failed"],
          )
        end
      end

      # `upgrade: safe|yes|dist|full` with no `name:` - dispatched through
      # run_upgrade_backend, which mirrors apt.py's upgrade(): aptitude is
      # preferred for safe/yes/full whenever it is installed, dist always
      # stays on apt-get. The task registers this result and computes its
      # own `changed_when` from `.stdout`, so the raw command output has
      # to actually reach the registered var's `stdout` field, not just
      # inform `changed`/`msg` here - passed through via the `stdout:`
      # kwarg the same way the package-install path below already does.
      upgrade_stdout = ""
      upgrade_stderr = ""
      upgrade_zero_effect = false
      upgrade_warnings = [] of String
      if upgrade
        # Real upgrade()'s EXACT command format lives in
        # run_upgrade_backend - the empty flag fields KEEP their
        # separators, and upgrade_command itself carries a trailing space
        # whenever autoremove is unset on the apt-get paths
        # ("dist-upgrade " / "upgrade --with-new-pkgs "). That exact
        # string is what Ansible's failure msg quotes ("'%s %s' failed:
        # %s" over the resolved apt_cmd and upgrade_command), so the
        # spacing is load-bearing for wording parity, not cosmetics. Like
        # install(), the command RUNS in check mode too - with --simulate
        # - and its output is the registered stdout (round-99500x
        # apt_check_upgrade capture).
        run = run_upgrade_backend(upgrade, autoremove, lock_timeout)
        if run[:exit_code] != 0
          # Real upgrade() failure: fail_json(msg="'%s %s' failed: %s"
          # % (apt_cmd, upgrade_command, err), stdout=out, rc=rc) - NO
          # stderr key at all (round-99500x capture).
          failure = PluginResult.new(
            changed: false,
            failed: true,
            msg: "'#{run[:apt_cmd]} #{run[:upgrade_command]}' failed: #{run[:stderr]}",
            stdout: run[:stdout],
            rc: run[:exit_code],
            key_order: ["stdout", "rc", "failed", "msg"]
          )
          attach_upgrade_warnings(failure, run[:warnings])
          return failure
        end

        upgrade_stdout = run[:stdout]
        upgrade_stderr = run[:stderr]
        upgrade_zero_effect = run[:zero_effect]
        changed = !upgrade_zero_effect
        messages << run[:stdout]
        upgrade_warnings = run[:warnings]
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
            upgraded_result = PluginResult.new(
              changed: changed,
              failed: false,
              msg: msg,
              stdout: upgrade_stdout,
              stderr: upgrade_stderr,
              diff: upgrade_zero_effect ? nil : apt_install_diff(upgrade_stdout),
              key_order: exit_keys
            )
            attach_upgrade_warnings(upgraded_result, upgrade_warnings)
            return upgraded_result
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
            upgraded_result = PluginResult.new(
              changed: changed,
              failed: false,
              msg: msg,
              stdout: upgrade_stdout,
              stderr: upgrade_stderr,
              diff: upgrade_zero_effect ? nil : apt_install_diff(upgrade_stdout),
              key_order: exit_keys
            )
            attach_upgrade_warnings(upgraded_result, upgrade_warnings)
            return upgraded_result
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

    # apt.py routes a name containing any of `*?[]!` through its fnmatch
    # expansion, which fails a no-match with the plural "No package(s)
    # matching 'X' available" (no "is") instead of the plain-name wording.
    private def no_package_msg(name : String) : String
      if name.matches?(/[*?\[\]!]/)
        "No package(s) matching '#{name}' available"
      else
        "No package matching '#{name}' is available"
      end
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
      version = candidates[pkg]? || pinned_version || candidates[base_name]?
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
    # recreate_cache: up to two `apt-get update -q` tries; the LAST
    # try's rc/stdout/stderr are returned (2.21's own recreate_cache
    # shape - note the loop re-runs on failure only).
    private def recreate_apt_cache : {Int32, String, String}
      rc = 1
      stdout = ""
      stderr = ""
      2.times do
        result = remote_exec("apt-get update -q")
        rc = result[:exit_code]
        stdout = result[:stdout].to_s
        stderr = result[:stderr].to_s
        break if rc == 0
      end
      {rc, stdout, stderr}
    end

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
      !resolve_pinned_version(name, version).nil?
    end

    # Ansible hands apt-get the concrete cache version a wildcard pin
    # matched first (`unifi=5.6.42*` -> `'unifi=5.6.42-10376-1'`), never
    # the raw pattern.
    private def resolve_pinned_version(name : String, version : String) : String?
      probe = remote_exec("apt-cache policy #{shell_single_quote(name)}")
      return nil unless probe[:exit_code] == 0
      # Ansible matches the pin against the version table only - the
      # package header (`htop:`) and the Installed:/Candidate: lines are
      # never candidates, so a `*` pin must not resolve to the header.
      # Below the "Version table:" marker, rows at the table's own
      # indentation are versions (the installed row's `***` marker reads
      # as blank, per apt-cache's column layout); the deeper-indented
      # rows under it are the per-mirror origin lines.
      lines = probe[:stdout].split('\n')
      start = lines.index(&.includes?("Version table:")) || return nil
      table_indent : Int32? = nil
      lines[(start + 1)..].each do |raw|
        line = raw.gsub("***", "   ")
        stripped = line.strip
        indent = line.size - line.lstrip.size
        table_indent = indent if table_indent.nil? && !stripped.empty?
        base = table_indent
        break if base.nil? || stripped.empty? || indent < base
        next if indent > base
        next unless first = stripped.split.first?
        return first if version_pin_matches?(version, first)
      end
      nil
    end

    # fnmatch.fnmatch semantics for an apt version pin: `*`, `?` and
    # `[...]` classes; a pin without a wildcard is an exact comparison.
    private def version_pin_matches?(pin : String, candidate : String) : Bool
      return pin == candidate unless pin.matches?(/[*?\[]/)
      regex = String.build do |io|
        io << "\\A"
        pin.each_char do |char|
          case char
          when '*'      then io << ".*"
          when '?'      then io << '.'
          when '[', ']' then io << char
          else               io << Regex.escape(char.to_s)
          end
        end
        io << "\\z"
      end
      Regex.new(regex).matches?(candidate)
    rescue Regex::Error
      pin == candidate
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

    # Real package_status()'s lone-installed-provider resolution for a
    # purely virtual name (see handle_latest's spec_list): the provider's
    # candidate version becomes the pin when the provider is installed at
    # any other version; nil otherwise (provider absent, multiple
    # providers, or already at the candidate - the bare-spec paths).
    private def virtual_provider_pin(name : String) : String?
      providers = apt_reverse_provides_batch([name])[name]?
      return nil unless providers && providers.size == 1
      provider = providers[0]
      statuses = dpkg_installed_status([provider])
      status = statuses[provider]?
      return nil unless status && status[0]
      installed_version = status[1]
      _resolvable, provider_candidate = apt_candidate(provider)
      return nil unless provider_candidate
      installed_version == provider_candidate ? nil : provider_candidate
    end

    # Real package_status()'s virtual-name resolution for the installed
    # split: a name the apt cache only knows as virtual (apt-cache
    # policy's "Candidate: (none)", i.e. no versions of its own) that
    # exactly one package Provides: counts as INSTALLED when that lone
    # provider is, at the provider's own version. Ansible then keeps the
    # name off the apt-get command line entirely, so a satisfied virtual
    # name is "ok" even in check mode (live-verified vs
    # ansible-playbook 2.21.6: a libparted2 whose provider libparted2t64
    # is installed is ok). dpkg_installed_status only ever records the
    # requested names themselves and a purely virtual name never has a
    # dpkg record of its own, so without this every check-mode run went
    # on to run apt-get --simulate and report changed for a package apt
    # already satisfies (issue #1102, fede2cr.alfresco52's libglu-dev,
    # provided solely by libglu1-mesa-dev).
    #
    # Everything else keeps real's own split: a real-but-absent package's
    # Provides: relationship is irrelevant, and a virtual name with more
    # than one provider is upstream's "let apt-get sort it out" bare-spec
    # path (which does reach apt-get, hence changed in check mode).
    private def with_virtual_provider_installs(installed_status : Hash(String, {Bool, String?, String}), base_names : Array(String)) : Hash(String, {Bool, String?, String})
      missing = base_names.uniq.select do |name|
        next false if name.empty?
        status = installed_status[name]?
        status.nil? || !status[0]
      end
      return installed_status if missing.empty?

      candidates = apt_candidates_batch(missing)
      virtual = missing.select do |name|
        candidate = candidates[name]?
        candidate && candidate[0] && candidate[1].nil?
      end
      return installed_status if virtual.empty?

      providers = apt_reverse_provides_batch(virtual)
      lone_providers = virtual.compact_map do |name|
        found = providers[name]? || [] of String
        found.size == 1 ? {name, found[0]} : nil
      end
      return installed_status if lone_providers.empty?

      provider_status = dpkg_installed_status(lone_providers.map(&.[1]).uniq!)
      lone_providers.each do |(name, provider)|
        status = provider_status[provider]?
        next unless status && status[0]
        installed_status[name] = status
      end
      installed_status
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
      install_failure : PluginResult? = nil

      # One batched dpkg-query round trip for the whole list (see
      # dpkg_installed_status), shared by the candidate probe and the
      # to_install split below. build-dep never consults installed-ness
      # (real install() hands every spec straight to apt-get there).
      installed_status = dpkg_installed_status(packages)
      unless build_dep
        installed_status = with_virtual_provider_installs(installed_status, packages.map { |pkg| split_name_version(pkg)[0] })
      end

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
            if resolved = resolve_pinned_version(base_name, pinned_version)
              candidates[pkg] = resolved
            else
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
            # A name that is only referenced by other packages'
            # dependencies still prints an `apt-cache policy` stanza
            # ("Candidate: (none)"), but python-apt sees no versions and
            # no providers, so it is a miss too - the same provider walk
            # handle_latest below does (live-verified vs
            # ansible-playbook 2.19.11: `state: present` on
            # virtualbox-5.2 fails "No package matching 'virtualbox-5.2'
            # is available" in normal AND check mode, before any apt-get
            # call). Installed names never reach this branch (the
            # installed short-circuit above skips them), so the provider
            # probe alone decides here.
            if !resolvable || (candidate.nil? && (apt_reverse_provides_batch([base_name])[base_name]? || [] of String).empty?)
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: no_package_msg(base_name)
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
        # Ansible fnmatches a wildcard pin against the installed version
        # too, so an installed `bash=5.*` is a no-op, not a raw-glob install.
        if installed && (pinned_version.nil? || ((iv = installed_ver) && version_pin_matches?(pinned_version, iv)))
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
        # The locale is Ansible's get_best_parsable_locale result, not a
        # hardcoded 'C': under C.UTF-8 the dpkg/systemd output this stdout
        # captures (e.g. "Created symlink ... → ...") differs from the C
        # locale's ASCII form (issue #449).
        exec_cmd = "#{apt_environment_prefix} #{install_cmd}"
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
          install_failure = PluginResult.new(
            changed: changed,
            failed: true,
            msg: "'#{install_cmd}' failed: #{install_result[:stderr]}",
            stdout: install_result[:stdout],
            stderr: install_result[:stderr],
            stdout_lines: PluginHelpers::AnsibleSplitlines.split(install_result[:stdout]),
            stderr_lines: PluginHelpers::AnsibleSplitlines.split(install_result[:stderr]),
            rc: install_result[:exit_code],
            cache_update_time: @cache_update_time,
            key_order: ["stdout", "stderr", "rc", "cache_updated", "cache_update_time", "failed", "msg", "stdout_lines", "stderr_lines"]
          )
        end
      end

      # apt.py's install() marks every requested spec's base name as
      # manually installed on the way out of every exit it reaches -
      # whether apt-get installed something, found everything already
      # satisfied (the empty-command case just below), or failed - and
      # mark_installed()'s own fail_json preempts that install result
      # (the round-1794194103 grycap.weave NVIDIA.nvidia_driver capture:
      # ansible reported "Command '/usr/bin/apt-mark manual ...'
      # failed.", this engine reported apt-get's own failure).
      #
      # install_deb()'s dependency pre-install is the one caller left
      # out: real marks those manual here and then AUTO again right
      # after (mark_installed(manual=False)), and this engine does not
      # implement the second half, so marking them manual here alone
      # would leave a .deb's dependencies manual where apt had them auto.
      unless build_dep || deb_deps
        if mark_failure = apt_mark_manual_failure(packages)
          return mark_failure
        end
      end
      return install_failure if install_failure

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

    # apt.py's mark_installed(m, package_names, manual=True): one
    # `apt-mark manual <names>` run over every requested spec's base
    # name, whose failure is a fail_json of its own shape
    # ("Command '<cmd>' failed." plus stdout/stderr/rc, no cache keys -
    # mark_installed exits before main() appends them) that preempts the
    # install result. Skipped in check mode for the same reason apt.py
    # gates it on `not m.check_mode`: it mutates dpkg's extended_states.
    private def apt_mark_manual_failure(packages : Array(String)) : PluginResult?
      return nil if @check_mode
      names = packages.map { |pkg| split_name_version(pkg)[0] }.reject(&.empty?)
      return nil if names.empty?
      mark_bin = apt_mark_bin
      return nil if mark_bin.empty?
      cmd = "#{mark_bin} manual #{names.map { |name| shell_single_quote(name) }.join(" ")}"
      mark_result = remote_exec(cmd)
      return nil if mark_result[:exit_code] == 0
      # mark_installed() fails out of its own fail_json before main()
      # appends cache_updated/cache_update_time - real's registered result
      # carries neither.
      @omit_cache_updated = true
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Command '#{mark_bin} manual #{names.join(" ")}' failed.",
        stdout: mark_result[:stdout],
        stderr: mark_result[:stderr],
        rc: mark_result[:exit_code],
        stdout_lines: PluginHelpers::AnsibleSplitlines.split(mark_result[:stdout]),
        stderr_lines: PluginHelpers::AnsibleSplitlines.split(mark_result[:stderr]),
        key_order: ["stdout", "stderr", "rc", "failed", "msg", "stdout_lines", "stderr_lines"]
      )
    end

    # apt.py's get_bin_path("apt-mark") - empty when the host has no
    # apt-mark at all, in which case real mark_installed() only warns and
    # the install result stands.
    private def apt_mark_bin : String
      @apt_mark_bin ||= begin
        probe = remote_exec("command -v apt-mark")
        probe[:stdout].strip
      end
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
      remove_result = with_policy_rc_d { apt_with_lock_retry("#{apt_environment_prefix} #{remove_cmd}", lock_timeout, ->remote_exec(String)) }
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
      # apt.py's main() calls upgrade(module, 'yes', ...) here - the SAME
      # dispatch run_upgrade_backend implements, aptitude included.
      run = run_upgrade_backend("yes", autoremove, lock_timeout)
      if run[:exit_code] != 0
        failure = PluginResult.new(
          changed: false,
          failed: true,
          msg: "'#{run[:apt_cmd]} #{run[:upgrade_command]}' failed: #{run[:stderr]}",
          stdout: run[:stdout],
          rc: run[:exit_code],
          key_order: ["stdout", "rc", "failed", "msg"]
        )
        attach_upgrade_warnings(failure, run[:warnings])
        return failure
      end

      zero_effect = run[:zero_effect]
      messages << run[:stdout]
      # Real apt.py's upgrade(): exit_json(changed=True, msg=out,
      # stdout=out, stderr=err, diff=diff) or its no-effect exit without
      # diff (round-99500x captures).
      wildcard_result = PluginResult.new(
        changed: !zero_effect,
        failed: false,
        msg: messages.join(", "),
        stdout: run[:stdout],
        stderr: run[:stderr],
        diff: zero_effect ? nil : apt_install_diff(run[:stdout]),
        key_order: zero_effect ? ["changed", "msg", "stdout", "stderr", "stdout_lines", "stderr_lines"] : ["changed", "msg", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"]
      )
      attach_upgrade_warnings(wildcard_result, run[:warnings])
      wildcard_result
    end

    # apt.py's install() cache resolution for state: latest (the
    # state=present handler above mirrors the same walk): every spec is
    # resolved against the apt cache BEFORE anything runs, and that
    # resolution is not check-mode gated - install() runs the same cache
    # lookup for state=latest as for present, so a name apt-cache has
    # never heard of fails "No package matching 'X' is available" before
    # any apt-get call (no cache_* keys), not apt-get's "has no
    # installation candidate", in normal AND check mode alike. Returns
    # the failure for the first unsatisfiable name, else the resolved
    # specs - each plain name pinned to its candidate ("name=candidate"),
    # the way real install() pins version_installable onto the apt-get
    # command line.
    private def resolve_latest_specs(packages : Array(String)) : PluginResult | Array(String)
      spec_list = [] of String
      packages.each do |pkg|
        base_name, pinned_version = split_name_version(pkg)
        resolvable, candidate = apt_candidate(base_name)
        # A name that is only referenced by other packages' dependencies
        # still prints an `apt-cache policy` stanza ("Candidate: (none)"),
        # but python-apt sees no versions and no providers, so it is a
        # miss too.
        unknown = !resolvable
        if !unknown && candidate.nil? && pinned_version.nil?
          no_providers = (apt_reverse_provides_batch([base_name])[base_name]? || [] of String).empty?
          unknown = no_providers && !(dpkg_installed_status([base_name])[base_name]?.try(&.[0]) || false)
        end
        if pinned_version.nil? && unknown
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: no_package_msg(base_name)
          )
        end
        version = pinned_version || candidate
        unless pinned_version || version || !resolvable
          # A purely virtual name (Candidate: (none)) with state=latest:
          # real package_status() resolves it through its providers - a
          # LONE provider that is already installed contributes its own
          # candidate as version_installable when the installed version
          # differs, and main() pins THAT onto the requested (virtual)
          # name: "git-core=1:2.34.1-1ubuntu1.17". apt-get then refuses a
          # version pin on a virtual name and the task FAILS, exactly as
          # captured in iroquoisorg.tools round 2300027 ("E: Version
          # '1:2.34.1-1ubuntu1.17' for 'git-core' was not found") - this
          # engine used to pass the bare virtual name through, letting
          # apt-get silently upgrade the provider and report changed.
          # Multi-provider or not-installed-provider virtual names take
          # real's "let apt sort it out" bare-spec path (unchanged).
          version = virtual_provider_pin(base_name)
        end
        spec_list << (version ? "#{base_name}=#{version}" : base_name)
      end
      spec_list
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

      # Every requested spec, for apt.py's trailing mark_installed (see
      # apt_mark_manual_failure): install() collects package_names from
      # EVERY spec before any skip/continue, so the only_upgrade filter
      # and wildcard resolution below must not narrow the mark list.
      # Marked on the way out of every exit EXCEPT the resolution
      # failures that return before apt.py's mark line (the empty-name,
      # "no available installation candidate" and "No package matching"
      # returns below), and never in check mode.
      requested_specs = packages

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
          if mark_failure = apt_mark_manual_failure(requested_specs)
            return mark_failure
          end
          messages << "No packages upgraded (only_upgrade skips packages that are not installed)"
          return PluginResult.new(changed: false, failed: false, msg: messages.join(", "))
        end
      end

      # Ansible's install() (state: latest flows through it with
      # upgrade=True) fnmatches a wildcard version pin against the
      # INSTALLED version before anything else: `bash=5.*` on a host
      # already at 5.2-1 is a plain no-op - no apt-get call at all - and
      # when the installed version does NOT match, the raw glob never
      # reaches apt-get either: install() resolves the pin against the
      # apt cache's version table and pins the CONCRETE match
      # (`bash=5.2-1`), failing "no available installation candidate"
      # when nothing matches - the same handling handle_install applies
      # for its own installed-version short-circuit and spec resolution.
      # Handing the glob to apt-get verbatim instead makes apt-get itself
      # reject the spec ("E: Version '5.*' ... was not found") where real
      # Ansible either no-ops or succeeds.
      wildcard_skipped = [] of String
      active_packages = packages
      any_wildcard_pin = packages.any? do |pkg|
        pin = split_name_version(pkg)[1]
        !pin.nil? && pin.matches?(/[*?\[]/)
      end
      if any_wildcard_pin
        wildcard_status = dpkg_installed_status(packages)
        active_packages = packages.compact_map do |pkg|
          base_name, pinned_version = split_name_version(pkg)
          next pkg if pinned_version.nil? || !pinned_version.matches?(/[*?\[]/)

          installed, installed_ver = wildcard_status[base_name]?.try { |pair| pair } || {false, nil}
          # Already installed at a version the glob matches: Ansible's
          # package_status() no-op - the package never reaches the apt-get
          # command line (or the check-mode simulate run below).
          if installed && (iv = installed_ver) && version_pin_matches?(pinned_version, iv)
            wildcard_skipped << pkg
            next nil
          end
          if resolved = resolve_pinned_version(base_name, pinned_version)
            "#{base_name}=#{resolved}"
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "no available installation candidate for #{pkg}",
              cache_update_time: @cache_update_time,
              key_order: ["cache_updated", "cache_update_time", "failed", "msg"]
            )
          end
        end
      end

      # Ansible's install() resolves every spec against the apt cache
      # BEFORE it runs anything, and that resolution is not check-mode
      # gated: a name apt-cache has never heard of fails "No package
      # matching 'X' is available" (no cache_* keys) before any apt-get
      # call in normal AND check mode alike (live-verified vs
      # ansible-playbook 2.21.6 - ajgarlag.logstash's "installing JAVA
      # package", round 29908288: ansible's --check output fails the
      # task with that message where this engine's check-mode simulate
      # run below reported "already at latest version" and ok). Resolved
      # up here so the check-mode branch fails the same way; normal mode
      # hands the resolved specs to its apt-get line below.
      resolved_specs = resolve_latest_specs(active_packages)
      if resolved_specs.is_a?(PluginResult)
        return resolved_specs
      end
      spec_list = resolved_specs

      # Every wildcard-pinned package was already installed at a version
      # its glob matches: nothing is left for apt-get (or the check-mode
      # simulate run) to act on at all - the same "already at latest
      # version" wording the unchanged path reports, changed: false.
      if wildcard_skipped.present? && active_packages.empty?
        messages << "Package#{packages.size > 1 ? "s" : ""} #{packages.join(", ")} already at latest version"
      elsif @check_mode
        # `grep -i upgrade` matched the ALWAYS-present "N upgraded, M newly
        # installed" summary line of simulate output, so check mode never
        # converged to ok. `^Inst` only matches an actual install/upgrade
        # action line.
        check_cmds = active_packages.map { |pkg| "apt-get install --simulate #{shell_single_quote(pkg)} 2>&1 | grep '^Inst'" }
        check_result = remote_exec(check_cmds.join(" || "))
        if check_result[:exit_code] == 0
          messages << "Would upgrade #{active_packages.join(", ")} to latest"
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
        # <fixed> <force> <autoremove> <fail_on_autoremove> <check_arg>
        # install <specs><trailing>` with the lock-timeout-augmented
        # dpkg_options and the resolved candidate pinned onto each spec
        # (live-verified: `apt-get -y -o Dpkg::Options::=--force-confdef
        # -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=60
        # install tree=2.0.2-1`). The plugin previously built its own
        # `apt-get install -y <opts> <flags> <name>` line, which no real
        # capture or apt.py format string produces.
        pkg_list = spec_list.map { |spec| naive_single_quote(spec) }.join(" ")
        # Real install()'s EXACT eight-slot format (same construction the
        # state=present path below mirrors): the `fixed` and `check_arg`
        # slots are always empty here - state=fixed routes through its own
        # handler and check mode returns through the simulate branch above
        # - but each empty slot KEEPS its separators, so the default shape
        # carries the seven-space run before "install" that Ansible's
        # "'cmd' failed" msg shows (buluma.handbrake round 29883637:
        # the five-space run this path used to emit diverged there).
        flags = [
          real_dpkg_options(lock_timeout),
          @only_upgrade ? "--only-upgrade" : "",
          "",
          @force ? "--force-yes" : "",
          true?(@params["autoremove"]?) ? "--auto-remove" : "",
          @fail_on_autoremove ? "--no-remove" : "",
          "",
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
          # apt.py's install() runs its trailing mark_installed before
          # returning even the rc!=0 data, and that fail_json preempts it
          # (see apt_mark_manual_failure).
          if mark_failure = apt_mark_manual_failure(requested_specs)
            return mark_failure
          end
          # Real install()'s rc!=0 failure msg: "'%s' failed: %s" over the
          # full apt-get command and stderr - the shape the round-2300027
          # git-core capture shows ("'/usr/bin/apt-get -y -o ... install
          # 'git-core=1:2.34.1-1ubuntu1.17'' failed: E: Version ... was not
          # found"); this path previously said its own "Failed to install
          # latest: ..." instead.
          # Real's failure data is dict(msg=..., stdout=out, stderr=err,
          # rc=rc) with main() appending the cache keys, and _return_formatted
          # adding the *_lines pair (buluma.handbrake round 29883637: the
          # bare-msg-only failure this path used to emit diverged there -
          # same shape the state=present failure below mirrors).
          return PluginResult.new(
            changed: changed,
            failed: true,
            msg: "'#{latest_cmd}' failed: #{upgrade_result[:stderr]}",
            stdout: upgrade_result[:stdout],
            stderr: upgrade_result[:stderr],
            stdout_lines: PluginHelpers::AnsibleSplitlines.split(upgrade_result[:stdout]),
            stderr_lines: PluginHelpers::AnsibleSplitlines.split(upgrade_result[:stderr]),
            rc: upgrade_result[:exit_code],
            cache_update_time: @cache_update_time,
            key_order: ["stdout", "stderr", "rc", "cache_updated", "cache_update_time", "failed", "msg", "stdout_lines", "stderr_lines"]
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
          messages << "Package#{packages.size > 1 ? "s" : ""} #{active_packages.join(", ")} upgraded to latest"
          changed = true
        else
          messages << "Package#{packages.size > 1 ? "s" : ""} #{packages.join(", ")} already at latest version"
        end
      end

      msg = messages.empty? ? "No changes needed" : messages.join(", ")
      if @check_mode && changed
        msg += " (check mode)"
      end

      if mark_failure = apt_mark_manual_failure(requested_specs)
        return mark_failure
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

    # `_apt_get_paths` is the no-apt-get guard's own seam (same
    # underscore-prefixed family as `_policy_rc_d_path`, and the same
    # seam apt_repository's gate uses) - the comma-separated paths its
    # File.exists? probe checks - so a spec can force the gate to fire
    # even on a dev box that really has apt-get. Never set by real
    # playbooks (Ansible has no such param and would reject it).
    private def apt_get_paths : Array(String)
      if override = @params["_apt_get_paths"]?
        override.split(',').map(&.strip).reject(&.empty?)
      else
        ["/usr/bin/apt-get", "/usr/local/bin/apt-get"]
      end
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

    # Real apt.py's APTITUDE_CMD: get_bin_path("aptitude", False) -
    # resolved absolute path, or nil when the host has no aptitude at
    # all. `_aptitude_paths` is a spec seam (same underscore-prefixed
    # family as `_apt_get_paths`, never set by real playbooks) letting a
    # spec point the probe at a fake binary; each override path is
    # probed with `test -x` since `command -v` only finds PATH entries.
    private def aptitude_bin : String?
      if override = @params["_aptitude_paths"]?
        return override.split(',').map(&.strip).reject(&.empty?).find do |path|
          remote_exec("test -x #{shell_single_quote(path)}")[:exit_code] == 0
        end
      end
      unless probed = @aptitude_bin
        probe = remote_exec("command -v aptitude")
        probed = probe[:stdout].strip.presence
        @aptitude_bin = probed
      end
      probed
    end

    # apt.py's upgrade(): the backend is NOT always apt-get. main()
    # resolves APTITUDE_CMD once (`get_bin_path("aptitude", False)`) and
    # sets `use_apt_get = p['force_apt_get']`, forced true only when
    # aptitude is absent - so with aptitude installed, safe/yes run
    # `aptitude safe-upgrade` and full runs `aptitude full-upgrade`,
    # while dist ALWAYS stays on `apt-get dist-upgrade`. The two
    # backends disagree on the result, not just the command: aptitude's
    # own zero-effect summary is APTITUDE_ZERO ("\n0 packages upgraded,
    # 0 newly installed, 0 to remove"), its force flag is
    # "--assume-yes --allow-untrusted", it takes neither --no-remove nor
    # --allow-downgrades (apt.py warns and drops both), and its command
    # string never carries the `--auto-remove` suffix the apt-get
    # branches fold in. thermistor.common's base packages install
    # aptitude, so its WARM `upgrade: safe` runs through aptitude while
    # the COLD run (aptitude not yet installed) used apt-get - and the
    # two binaries treat Ubuntu phased updates OPPOSITELY (apt-get
    # defers them, aptitude installs them regardless), which is exactly
    # the warm-run ansible=changed / krikri=ok divergence of issue
    # #1141. Returns everything the two upgrade call sites need: the
    # resolved binary (quoted verbatim by the failure msg), the exact
    # upgrade_command string, the raw run, the zero-effect screenscrape
    # verdict for whichever backend ran, and any aptitude-only warnings.
    private def run_upgrade_backend(mode : String, autoremove : Bool, lock_timeout : Int32) : NamedTuple(
      apt_cmd: String, upgrade_command: String, exit_code: Int32, stdout: String,
      stderr: String, zero_effect: Bool, warnings: Array(String))
      warnings = [] of String
      # dist NEVER routes through aptitude (real upgrade(): the dist
      # branch is checked before the aptitude selection and hardcodes
      # APT_GET_CMD).
      if (aptitude = mode == "dist" ? nil : (@force_apt_get ? nil : aptitude_bin))
        apt_cmd = aptitude
        upgrade_command = mode == "full" ? "full-upgrade" : "safe-upgrade"
        # Real upgrade()'s aptitude branches: both unsupported flags are
        # dropped with a warn, never passed to the binary.
        warnings << "APTITUDE does not support '--no-remove', ignoring the 'fail_on_autoremove' parameter." if @fail_on_autoremove
        warnings << "APTITUDE does not support '--allow-downgrades', ignoring the 'allow_downgrade' parameter." if @allow_downgrade
        force_flag = @force ? "--assume-yes --allow-untrusted" : ""
        fail_flag = ""
        unauth_flag = @allow_unauthenticated ? "--allow-unauthenticated" : ""
        downgrade_flag = ""
        zero_marker = "\n0 packages upgraded, 0 newly installed, 0 to remove"
      else
        apt_cmd = apt_get_bin
        upgrade_command = (mode == "dist" || mode == "full") ? "dist-upgrade" : "upgrade --with-new-pkgs"
        # "%s %s" % (upgrade_command, autoremove): the empty autoremove
        # field keeps the format string's trailing space, and that exact
        # string is what the failure msg quotes.
        upgrade_command += autoremove ? " --auto-remove" : " "
        force_flag = @force ? "--force-yes" : ""
        fail_flag = @fail_on_autoremove ? "--no-remove" : ""
        unauth_flag = @allow_unauthenticated ? "--allow-unauthenticated" : ""
        downgrade_flag = @allow_downgrade ? "--allow-downgrades" : ""
        zero_marker = "\n0 upgraded, 0 newly installed, 0 to remove"
      end

      # Real upgrade()'s EXACT command format: "%s -y %s %s %s %s %s %s
      # %s" over (apt_cmd_path, dpkg_options, force_yes,
      # fail_on_autoremove, allow_unauthenticated, allow_downgrade,
      # check_arg, upgrade_command) - the empty flag fields KEEP their
      # separators. Like install(), the command RUNS in check mode too -
      # with --simulate - and its output is the registered stdout
      # (round-99500x apt_check_upgrade capture).
      cmd = "#{apt_cmd} -y #{real_dpkg_options(lock_timeout)} #{force_flag} #{fail_flag} #{unauth_flag} #{downgrade_flag} #{@check_mode ? "--simulate" : ""} #{upgrade_command}"
      cmd += " -t #{naive_single_quote(@default_release.not_nil!)}" if @default_release

      # The upgrade contenders for the dpkg lock like every other apt op
      # - wrap with lock_timeout retry, inside the same policy-rc.d
      # lifecycle Ansible's upgrade() uses.
      result = with_policy_rc_d { apt_with_lock_retry("#{apt_environment_prefix} #{cmd}", lock_timeout, ->remote_exec(String)) }

      # The zero screenscrape uses a LEADING-newline match (both
      # markers): a summary whose upgraded-count merely ends in 0 ("10
      # upgraded, 0 newly installed, 0 to remove ...") must not
      # false-match at an inner offset.
      zero_effect = result[:stdout].includes?(zero_marker)
      {
        apt_cmd:         apt_cmd,
        upgrade_command: upgrade_command,
        exit_code:       result[:exit_code],
        stdout:          result[:stdout],
        stderr:          result[:stderr],
        zero_effect:     zero_effect,
        warnings:        warnings,
      }
    end

    # module.warn() attaches to whatever result the module eventually
    # exits with, so the aptitude-only upgrade warnings ride on the
    # upgrade result itself (success or failure alike).
    private def attach_upgrade_warnings(result : PluginResult, warnings : Array(String)) : Nil
      result.extra["warnings"] = JSON.parse(warnings.to_json) unless warnings.empty?
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
        initial_reason = apt_fetch_failure_reason(update_result)
        outcome = apt_fetch_failed_update_retry(update_cache_retries, update_cache_retry_max_delay, ->remote_exec(String),
          initial_reason: initial_reason,
          initial_trailing_refusal: apt_fetch_reason_trailing_refusal?(initial_reason))
        return nil if outcome[:recovered]
        # a fail_json exit carries no cache keys (the retvals assignment
        # in main() never runs) - suppress the engine-wide backfill
        @omit_cache_updated = true
        reason = outcome[:warnings].empty? ? "unknown reason" : outcome[:last_reason]
        result = PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to update apt cache after #{update_cache_retries} retries: #{reason}",
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
      # `_python_apt_absent` (SPEC_SEAMS) forces the absent answer so a
      # spec on a dev box that really has the bindings can still drive
      # the check-mode refusal and auto-install paths end to end.
      return false if true?(@params["_python_apt_absent"]?)
      apt_python_apt_present?(->remote_exec(String), @vars)
    end

    # apt.py's !HAVE_PYTHON_APT ladder's check-mode fail_json shape:
    # bare {"changed": false, "msg": ...} - NO cache keys at all (the
    # module never got to touch the cache; issue #1033's loop-item
    # lines are exactly {ansible_loop_var, changed, item, msg}), so the
    # cache-key backfill in #execute must be suppressed exactly like
    # the ENOENT guard's exit.
    private def check_mode_no_python_apt_result : PluginResult
      @omit_cache_updated = true
      PluginResult.new(
        changed: false,
        failed: true,
        msg: AptLockRetry::CHECK_MODE_NO_PYTHON_APT_MSG
      )
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

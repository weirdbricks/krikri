#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/rpm_package"
require "../src/krikri/plugin_helpers/run_command_failure"

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
  # `use_backend`. (2.19 still validates the retired `install_repoquery`
  # as a bool - live-verified - so it stays in the supported set.)
  #
  # Live-verified against ansible-core 2.21.4 on Fedora 41 (dnf5
  # 5.2.17): the whole option matrix is checked side-by-side in
  # testing/dnf5/dnf5_options.yml.
  class Dnf5Plugin < BasePlugin
    # ansible.builtin.dnf5's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.dnf5). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[allow_downgrade allowerasing auto_install_module_deps autoremove best bugfix
        cacheonly disable_gpg_check download_only install_repoquery install_weak_deps nobest
        security skip_broken sslverify update_cache update_only validate_certs]
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
      "dnf5"
    end

    # dnf5's exit_json call passes its kwargs in results/changed/msg/rc
    # order (its transaction tail is a literal
    # `exit_json(results=, changed=, msg=, rc=0)`), the reverse of dnf4's
    # response-dict order - and its `list:` path passes rc=0 where dnf4's
    # passes none. Both observed live on fedora:41 (key_order_sweep11).
    private def transaction_key_order : Array(String)
      DNF5_TRANSACTION_ORDER
    end

    private def list_result_key_order : Array(String)
      DNF5_LIST_ORDER
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
      # A bare spec goes through unquoted: remote_exec hands the command
      # to an ARGV splitter, so a shell-quoted spec reached dnf5 with its
      # quotes as part of the package name (see the shared list_args'
      # comment in plugin_helpers/rpm_package.cr).
      flag ? "list #{flag}" : "list #{query}"
    end

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      if failure = arg_spec_rejection
        return failure
      end

      normalize_best_param
      normalize_expire_cache_alias

      # argspec choices validation precedes ALL module-body work: an
      # explicit bad state must be reported before list queries or the
      # autoremove sanity check can return first (same live-verified shape
      # as dnf.cr; non-string values keep the later type-shaped check).
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

      # yumdnf.py's YumDnf.__init__ sanity check runs after the whole
      # argument-spec validation and before any module body - so even a
      # nameless autoremove task fails with this message on real ansible
      # instead of reaching the handle_autoremove short-circuit below
      # (which stays correct for the state-absent/omitted case).
      if rejection = yumdnf_autoremove_rejection
        return rejection
      end

      # dnf5.py's _ensure_dnf runs in Dnf5Module.__init__ - before run()'s
      # body and every early exit below (list: queries included): the module
      # cannot even start without the libdnf5 python bindings, and with
      # auto_install_module_deps at its argspec default (true) it first
      # tries to INSTALL them ("dnf install -y python3-libdnf5" through
      # check_rc=True run_command - a raw failure whose cmd/stdout/stderr/rc
      # shape IS the task's whole result). Rocky 10's repos carry no
      # python3-libdnf5, so every dnf5 task on one dies right here (issue
      # #767: this engine's native plugin skipped the bootstrap entirely and
      # reported ok where real failed). Same bug class as apt's python3-apt
      # module-start auto-install (apt_lock_retry.cr, issue #522): a real,
      # persistent host mutation, so check mode refuses it instead.
      if gate = libdnf5_import_gate
        return gate
      end

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
      unsupported_rejection || mutual_exclusion_rejection || bool_rejection || null_list_rejection
    end

    # Real dnf5's supported set = shared yumdnf_argument_spec + auto_install_module_deps
    # + best and (unlike dnf) WITHOUT use_backend. 2.19's dnf5 argspec
    # does still validate install_repoquery as a bool (live-verified:
    # `dnf5: {install_repoquery: blah}` fails with the bool wording), so
    # it stays supported here. The
    # trailing "(expire-cache, pkg)" is Ansible's aliases appended to the list.
    private def unsupported_rejection : PluginResult?
      dnf5_supported = {"allow_downgrade", "allowerasing", "auto_install_module_deps",
                        "autoremove", "best", "bugfix", "cacheonly", "conf_file",
                        "disable_excludes", "disable_gpg_check", "disable_plugin",
                        "disablerepo", "download_dir", "download_only", "enable_plugin",
                        "enablerepo", "exclude", "install_repoquery", "install_weak_deps", "installroot",
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
             "download_dir, download_only, enable_plugin, enablerepo, exclude, install_repoquery, install_weak_deps, " \
             "installroot, list, lock_timeout, name, nobest, releasever, security, skip_broken, " \
             "sslverify, state, update_cache, update_only, validate_certs (expire-cache, pkg)."
      )
    end

    # AnsibleModule fails a bool-typed arg given a non-boolean value
    # at module setup - now via the shared BasePlugin#validate_bool_params!
    # raised inside the same rejection chain, keeping Ansible's check order
    # (unsupported params -> bool types -> list coercion -> mutual
    # exclusion; see plugins/dnf.cr for the message-provenance story).
    private def bool_rejection : Nil
      validate_bool_params!
    end

    # AnsibleModule's `type: list` coercion fails an EXPLICIT None
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

    # AnsibleModule enforces the shared yumdnf `mutually_exclusive` pairs
    # (name|list, best|nobest) by plain key PRESENCE - `best: false` +
    # `nobest: false`, `list: ""` and even `list: null` all collide, and
    # every colliding group is reported in one message
    # (live-verified against ansible-core 2.19.11; see
    # RpmPackage#yumdnf_mutual_exclusion_rejection for the full provenance).
    private def mutual_exclusion_rejection : PluginResult?
      yumdnf_mutual_exclusion_rejection
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

    # ----- libdnf5 python-bindings bootstrap (dnf5.py's _ensure_dnf) -----

    # The import probe _ensure_dnf performs: the module's own interpreter
    # first, then the three system interpreters probe_interpreters_for_module
    # walks, respawning under the first one that can import the bindings.
    # One combined shell probe over those absolute paths answers the same
    # question in a single round trip (same shape as apt's python3-apt
    # probe in apt_lock_retry.cr).
    LIBDNF5_PROBE_CMD = "/usr/libexec/platform-python -c 'import libdnf5' 2>/dev/null || " \
                        "/usr/bin/python3 -c 'import libdnf5' 2>/dev/null || " \
                        "/usr/bin/python -c 'import libdnf5' 2>/dev/null"

    # The bootstrap command itself. dnf5.py passes the bare "dnf" name to
    # run_command - NOT this module's own dnf5 binary - so a failure's
    # reported cmd is exactly this space-joined string with no absolute
    # path, and the OSError case reports b'dnf'.
    LIBDNF5_AUTO_INSTALL_CMD = "dnf install -y python3-libdnf5"

    CHECK_MODE_NO_LIBDNF5_MSG = "python3-libdnf5 must be installed to use check mode. " \
                                "If run normally this module can auto-install it, " \
                                "see the auto_install_module_deps option."

    # fail_json's sorted dump order for both bootstrap failure shapes (the
    # raw run_command result carries cmd/rc/stdout/stderr around the msg) -
    # the same alphabetical order apt's python3-apt auto-install failure
    # dumps in (apt_lock_retry.cr, issue #522).
    LIBDNF5_BOOTSTRAP_FAILURE_ORDER = %w[changed cmd msg rc stderr stderr_lines stdout stdout_lines]

    # _libdnf5_probe is a spec seam only (never set by real playbooks): the
    # import probe uses absolute interpreter paths, unshimmable via PATH, so
    # a spec forces the probe's answer instead - "present" (bindings there,
    # bootstrap skipped), "absent" (every probe fails) or
    # "absent-then-present" (attempt 1 fails, the post-install re-probe
    # succeeds, mirroring a host the auto-install genuinely fixed).
    private def libdnf5_probe_says_present?(attempt : Int32) : Bool
      case @params["_libdnf5_probe"]?
      when "present"             then true
      when "absent"              then false
      when "absent-then-present" then attempt >= 2
      else                            remote_exec(LIBDNF5_PROBE_CMD)[:exit_code] == 0
      end
    end

    # auto_install_module_deps defaults to true in dnf5's argspec.
    private def auto_install_module_deps? : Bool
      true?(@params["auto_install_module_deps"]?, true)
    end

    # Returns the PluginResult the task fails with when the libdnf5 bindings
    # cannot be made importable, or nil when the module may proceed (the
    # bindings were already there, or the auto-install just put them there
    # and real's respawn would find them). Mirrors _ensure_dnf's two
    # attempts: probe, then (check mode refusal | auto-install | give up),
    # then a final probe before the could-not-import failure.
    private def libdnf5_import_gate : PluginResult?
      return nil if libdnf5_probe_says_present?(1)

      if check_mode?
        return PluginResult.new(changed: false, failed: true, msg: CHECK_MODE_NO_LIBDNF5_MSG)
      end

      if auto_install_module_deps?
        if failure = PluginHelpers::RunCommandFailure.exec_check("dnf")
          return libdnf5_bootstrap_enoent_result(failure[0], failure[1])
        end
        result = remote_exec(LIBDNF5_AUTO_INSTALL_CMD)
        unless result[:exit_code] == 0
          failed = PluginHelpers::RunCommandFailure.nonzero_exit(LIBDNF5_AUTO_INSTALL_CMD, result[:exit_code], result[:stdout], result[:stderr])
          failed.key_order = LIBDNF5_BOOTSTRAP_FAILURE_ORDER
          return failed
        end
        return nil if libdnf5_probe_says_present?(2)
      end

      could_not_import_libdnf5_result
    end

    # The never-started-exec shape: run_command's Popen raised OSError
    # (no `dnf` binary anywhere on the target - a Debian-family container
    # carrying no dnf at all), so fail_json reports rc=errno, EMPTY
    # stdout/stderr(+_lines) and the bare "Error executing command." msg
    # while the [ERROR] block renders the Errno text from the exception
    # field - here carried as _ansible_error_detail like apt's identical
    # auto-install ENOENT (live-verified: "Task failed: Module failed:
    # Error executing command: [Errno 2] No such file or directory:
    # b'dnf'").
    private def libdnf5_bootstrap_enoent_result(errno : Int32, reason : String) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Error executing command.",
        cmd: LIBDNF5_AUTO_INSTALL_CMD,
        rc: errno,
        stdout: "",
        stderr: "",
        stdout_lines: [] of String,
        stderr_lines: [] of String,
        key_order: LIBDNF5_BOOTSTRAP_FAILURE_ORDER,
        _ansible_error_detail: "Error executing command: [Errno #{errno}] #{reason}: b'dnf'"
      )
    end

    # _ensure_dnf's terminal failure (auto_install_module_deps: false, or
    # the bindings still unimportable after a successful install): the
    # module names the interpreter it ran under plus that interpreter's
    # own sys.version. The probe asks the first system interpreter that
    # exists for exactly those two values - os.path.realpath(sys.executable)
    # because discovery resolves the unversioned python3 symlink to the
    # versioned binary it reports (e.g. /usr/bin/python3.12).
    private def could_not_import_libdnf5_result : PluginResult
      raw = remote_exec(LIBDNF5_INTERPRETER_PROBE_CMD)[:stdout].strip
      exe, version = if idx = raw.index(" (")
                       {raw[0...idx], raw[(idx + 2)..].rstrip(")")}
                     else
                       {"/usr/bin/python3", ""}
                     end
      PluginResult.new(
        changed: false,
        failed: true,
        # dnf5.py's terminal _ensure_dnf fail_json passes failures=[] (its
        # dnf-compat transaction-failure list, empty here because the module
        # never got as far as a transaction) - omitting it leaves the key out
        # of both the fatal line and any registered result (issue #770).
        msg: "Could not import the libdnf5 python module using #{exe} (#{version}). " \
             "Ensure python3-libdnf5 package is installed (either manually or via the auto_install_module_deps option) " \
             "or that you have specified the correct ansible_python_interpreter. " \
             "(attempted ['/usr/libexec/platform-python', '/usr/bin/python3', '/usr/bin/python']).",
        failures: [] of String
      )
    end

    LIBDNF5_INTERPRETER_PROBE_CMD = %{for py in /usr/libexec/platform-python /usr/bin/python3 /usr/bin/python; do [ -x "$py" ] && exec "$py" -c 'import sys, os; sys.stdout.write(os.path.realpath(sys.executable) + " (" + sys.version.replace(chr(10), "") + ")")'; done}

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

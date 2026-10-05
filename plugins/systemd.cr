#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/systemd_enabled_state"
require "../src/krikri/plugin_helpers/systemd_cli_flags"
require "../src/krikri/plugin_helpers/systemd_unit_found"

module Krikri
  # Systemd Plugin - Manage systemd units
  #
  # Parameters:
  #   name (optional): Unit name (e.g. nginx, nginx.service, ctrl-alt-del.target)
  #   state (optional): started, stopped, restarted, reloaded
  #   enabled (optional): yes/no - enable on boot
  #   masked (optional): yes/no - mask/unmask the unit
  #   daemon_reload (optional): yes/no - run `systemctl daemon-reload`
  #   daemon_reexec (optional): yes/no - run `systemctl daemon-reexec`
  #   force (optional): yes/no - pass `--force` to the enable/disable/
  #     mask/unmask invocations
  #   no_block (optional): yes/no - pass `--no-block` to the state-changing
  #     invocations (start/stop/restart/reload) so they return immediately
  #   check_mode (optional): Dry-run mode
  #
  # Matches the ansible.builtin.systemd module's semantics for the
  # parameters os_hardening and other real roles use: an optional name
  # (a daemon_reload-only task has no unit), state management via
  # systemctl start/stop/restart/reload, boot enablement, and masking.
  #
  # Examples:
  #   systemd:
  #     name: ctrl-alt-del.target
  #     masked: yes
  #     daemon_reload: yes
  #   systemd:
  #     daemon_reload: yes
  class SystemdPlugin < BasePlugin
    # ansible.builtin.systemd's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.systemd). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[daemon_reexec daemon_reload enabled force masked no_block]
    end

    protected def bool_param_aliases : Hash(String, String)
      {
        "daemon-reexec" => "daemon_reexec",
        "daemon-reload" => "daemon_reload",
      }
    end

    # These default to None in Ansible's argspec, so an explicit null
    # skips type validation there (see BasePlugin#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[enabled force masked]
    end

    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute : PluginResult
      validate_bool_params!
      # AnsibleModule argument-spec validation: any key outside real
      # Ansible's argument_spec (the Ansible module: name/
      # service/unit, state, enabled, force, masked, daemon_reload/
      # daemon-reload, daemon_reexec/daemon-reexec, scope, no_block) aborts
      # the task BEFORE the module runs. Round 813233 (role
      # libre_ops.multi_redis) passes `systemd: {name: ..., status: ...}` -
      # `status` is not a parameter of this module at all - and real
      # ansible-playbook rejects the task with the message below, while
      # this plugin silently ignored the unknown key and ran anyway.
      # check_mode/diff_mode/_verbosity/_environment are engine-internal
      # keys injected by BasePlugin/the executor, not part of the real
      # argument_spec, so they must not be rejected. (_verbosity omission
      # found via podman-diff: every systemd task failed with
      # "Unsupported parameters ... _verbosity" before the module ever
      # ran - Ansible never passes _verbosity into module args.)
      supported_params = {"name", "service", "unit", "state", "enabled",
                          "masked", "daemon_reload", "daemon-reload",
                          "daemon_reexec", "daemon-reexec", "force",
                          "no_block", "scope"}
      internal_keys = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| supported_params.includes?(k) || internal_keys.includes?(k) || k.starts_with?("_") }
      unless unsupported.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (systemd) module: #{unsupported.sort.join(", ")}. " \
               "Supported parameters include: " \
               "daemon_reexec, daemon_reload, enabled, force, masked, name, no_block, scope, state " \
               "(daemon-reexec, daemon-reload, service, unit)."
        )
      end

      # name/daemon_reload/daemon_reexec all have Ansible-documented
      # hyphenated aliases (`ansible-doc ansible.builtin.systemd`: name's
      # are service/unit; daemon_reload's is daemon-reload; daemon_
      # reexec's is daemon-reexec) - found via round171's buluma.gitea,
      # whose own "Systemctl daemon-reload" handler writes `daemon-
      # reload: true` (the alias spelling, not the canonical param name).
      # Previously only the canonical name was read, so this handler hit
      # the "no action" guard below and failed outright every time its
      # notifying task actually changed something, instead of running
      # the reload ansible-playbook performs.
      name = @params["name"]? || @params["service"]? || @params["unit"]?
      state = @params["state"]?
      enabled = @params["enabled"]?
      masked = @params["masked"]?
      daemon_reload = true?(@params["daemon_reload"]? || @params["daemon-reload"]?)
      # daemon_reexec: yes/no - `systemctl daemon-reexec`, re-executing
      # systemd itself (distinct from daemon-reload). Entirely
      # unimplemented before - fell into the "no action" guard below,
      # found via robertdebock.mysql's own "Systemctl daemon-reexec"
      # handler (`ansible.builtin.systemd: {daemon_reexec: true}`, no
      # other params at all - round 18), which failed outright instead
      # of running the reexec ansible-playbook performs.
      daemon_reexec = true?(@params["daemon_reexec"]? || @params["daemon-reexec"]?)
      force_flag = SystemdCliFlags.force_flag(@params["force"]?)
      no_block_flag = SystemdCliFlags.no_block_flag(@params["no_block"]?)

      # AnsibleModule argument validation (the Ansible module's
      # own required_one_of/required_by), both presence-based - a given-but-
      # false daemon_reload still satisfies required_one_of, and a given
      # state/enabled/masked requires a name even when falsy:
      # required_one_of=[['state', 'enabled', 'masked', 'daemon_reload',
      # 'daemon_reexec']], required_by={state/enabled/masked: name}. The
      # daemon_reload/daemon_reexec aliases count because Ansible
      # resolves them onto the canonical params before the check. A name
      # (or its service/unit aliases) alone also satisfies it: real
      # Ansible's module takes a name-only call as a QUERY - it runs
      # `systemctl show <name>` and populates result['status'] with the
      # unit's current properties (changed stays False, no management
      # action runs) - konstruktoid.hardening's own "Get ctrl-alt-del.
      # target information" task does exactly this and registers the
      # result for a later task to read .status.FragmentPath from (rounds
      # 975062/978000: this used to fail outright instead). Only a call
      # with truly nothing - no name AND no action param - fails with
      # required_one_of's message. Replaces the previous ad-hoc guards
      # (different wording, truthiness-based, and daemon_reload: false
      # alone failed instead of succeeding as a no-op the way real
      # Ansible does).
      unless name || @params["state"]? || @params["enabled"]? || @params["masked"]? ||
             @params["daemon_reload"]? || @params["daemon-reload"]? ||
             @params["daemon_reexec"]? || @params["daemon-reexec"]?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "one of the following is required: state, enabled, masked, daemon_reload, daemon_reexec"
        )
      end

      # systemctl only accepts units or unit paths; a bare name like
      # "nginx" is resolved by systemctl itself, so no normalization is
      # needed. But commands that need a unit require name present
      # (name/service/unit aliases all satisfy Ansible's required_by).
      {"state", "enabled", "masked"}.each do |key|
        if @params[key]? && name.nil?
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "missing parameter(s) required by '#{key}': name"
          )
        end
      end

      changed = false
      messages = [] of String

      # daemon_reload: no unit needed. Always actually runs the reload
      # (systemctl daemon-reload has no reliable "was anything stale"
      # signal to check first), but does NOT set changed - verified
      # against a ansible-playbook run of dev-sec os_hardening's own
      # "Reload systemd" handler (`ansible.builtin.systemd: {daemon_reload:
      # true}`, no name:/state:), which reported `ok:` every time, never
      # `changed:`. Previously set changed: true unconditionally here,
      # so a handler notified only for its side effect (systemd picking
      # up a changed unit file) showed as "changed" on every run even
      # when nothing else in the task changed - Ansible's own
      # module has no notion of daemon-reload "changedness" at all.
      if daemon_reload
        if @check_mode
          messages << "Would reload systemd daemon"
        else
          reload_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} daemon-reload")
          if reload_result[:exit_code] == 0
            messages << "Systemd daemon reloaded"
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "failure #{reload_result[:exit_code]} during daemon-reload: #{reload_result[:stderr]}"
            )
          end
        end
      end

      # daemon_reexec: same "no reliable changed signal" reasoning as
      # daemon_reload above - always actually runs it, never sets changed.
      if daemon_reexec
        if @check_mode
          messages << "Would re-execute systemd daemon"
        else
          reexec_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} daemon-reexec")
          if reexec_result[:exit_code] == 0
            messages << "Systemd daemon re-executed"
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "failure #{reexec_result[:exit_code]} during daemon-reexec: #{reexec_result[:stderr]}"
            )
          end
        end
      end

      # enabled:/masked: probe the unit first; with no systemd running Ansible's
      # run_command result becomes the failure. Its cmd is the bare
      # `module.run_command(systemctl, check_rc=True)` call the module
      # reaches after show/is-enabled/list-unit-files all fail - the FULL
      # prefix real builds once up front (systemd_service.py:377-386:
      # scope flag, then --no-block, then --force - live-verified vs
      # 2.19.11: force → "/usr/bin/systemctl --force",
      # no_block+force → "/usr/bin/systemctl --no-block --force",
      # scope user+force → "/usr/bin/systemctl --user --force").
      # (a unit with a SysV init script counts as found and skips this)
      #
      # Ansible also computes its one-and-only `found` decision right here
      # (systemd_service.py: `found = is_systemd or is_initd`, BEFORE the
      # masked block), from this same `systemctl show` probe plus the
      # SysV init-script check. It used to be missing entirely from this
      # plugin: nothing here ever asked whether the unit existed, so a
      # `systemd_service: {name: <absent unit>, enabled: false, state:
      # stopped, masked: true}` task masked a unit that isn't installed
      # (which Ansible does too - `systemctl mask` happily creates the /etc/
      # systemd/system symlink for a never-installed unit) and then
      # disable'd/stop'd it, reporting `changed`, where Ansible fails the
      # enabled:/state: steps through fail_if_missing and reports nothing
      # but the swallowed "Could not find the requested service" message.
      # Found via konstruktoid.hardening's kdump.service / kdump-tools.
      # service / systemd-journal-remote.* / atd tasks on Ubuntu 22.04,
      # each of which pairs a failed_when that swallows that exact message
      # (rounds 999001).
      found = true
      if name
        # Ansible's is_initd (its sysv_exists(), /etc/init.d/<name> minus a
        # trailing .service) - a SysV script alone makes the unit "found"
        # even with no systemd unit file at all.
        is_initd = File.exists?("/etc/init.d/#{name.to_s.sub(/\.service\z/, "")}")
        unless is_initd
          probe = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} show #{shell_single_quote(name.to_s)}")
          if no_bus_failure?(probe[:stderr])
            bin = remote_exec("command -v systemctl")[:stdout].strip
            bin = "/usr/bin/systemctl" if bin.empty?
            err = probe[:stderr]
            return PluginResult.new(changed: false, failed: true, msg: err.strip,
              cmd: "#{bin}#{scope_flag}#{no_block_flag}#{force_flag}", rc: probe[:exit_code],
              stdout: probe[:stdout], stdout_lines: probe[:stdout].lines.map(&.chomp),
              stderr: err, stderr_lines: err.lines.map(&.chomp))
          end
          found = SystemdUnitFound.found?(probe[:exit_code], probe[:stdout].to_s, false)
        end
      end

      # Masked/unmasked
      if masked
        should_mask = true?(masked)
        is_masked = masked?(name || raise "systemd: name is required")

        if should_mask && !is_masked
          if @check_mode
            messages << "Would mask #{name}"
            changed = true
          else
            mask_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{force_flag} mask #{shell_single_quote(name.to_s)}")
            if mask_result[:exit_code] == 0
              messages << "Unit masked"
              changed = true
            else
              # Ansible's mask/unmask failure path: fail_if_missing runs
              # FIRST, so on a unit systemd doesn't know about the missing
              # -service message is what surfaces, and the action-specific
              # wording ("Failed to mask/unmask the service (...)") is
              # only for a unit that does exist and failed for some other
              # reason. `systemctl mask` normally succeeds even for a
              # never-installed unit (that is how a role can pre-mask
              # something a package might install later), so this branch is
              # rarely taken - but when it is, the wording is Ansible's.
              if !found
                return PluginResult.new(changed: false, failed: true,
                  msg: SystemdUnitFound.missing_service_message(name.to_s))
              end
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to mask the service (#{name}): #{mask_result[:stderr].strip}"
              )
            end
          end
        elsif !should_mask && is_masked
          if @check_mode
            messages << "Would unmask #{name}"
            changed = true
          else
            unmask_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{force_flag} unmask #{shell_single_quote(name.to_s)}")
            if unmask_result[:exit_code] == 0
              messages << "Unit unmasked"
              changed = true
            else
              if !found
                return PluginResult.new(changed: false, failed: true,
                  msg: SystemdUnitFound.missing_service_message(name.to_s))
              end
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to unmask the service (#{name}): #{unmask_result[:stderr].strip}"
              )
            end
          end
        end
      end

      # Ansible's fail_if_missing(module, found, unit, msg='host'), called at
      # the top of the `enabled:` block and again at the top of the
      # `state:` one - presence-based (a given-but-false `enabled:` counts),
      # enabled's check first, and mode-independent (Ansible runs it in check
      # mode too). Deliberately placed AFTER the masked block: real masks a
      # unit before it ever checks whether that unit exists, and the mask
      # side effect must have happened by the time this failure is returned.
      # A masked-only task on an absent unit is therefore still a success
      # with changed=true, exactly as real leaves it. fail_json carries only
      # the message (Ansible's fail_if_missing passes no `changed`), so the
      # swallowed failure renders `ok` - which is what konstruktoid.
      # hardening's failed_when expects.
      if enabled && !found
        return PluginResult.new(changed: false, failed: true,
          msg: SystemdUnitFound.missing_service_message(name.to_s))
      end
      if state && !found
        return PluginResult.new(changed: false, failed: true,
          msg: SystemdUnitFound.missing_service_message(name.to_s))
      end

      name_for_active = name

      # Top-level result fields Ansible's module returns. Real
      # systemd_service.py builds `result = dict(name=unit, changed=False,
      # status=dict())` and then adds `enabled` (a bool: the unit's current
      # is-enabled state, or the post-change one when enable/disable ran -
      # set even in check mode) only when the `enabled:` param was given,
      # and `state` (the requested state string, normalized to 'started'
      # for restarted/reloaded) only when `state:` was given. Top-level -
      # konstruktoid.hardening's timesyncd.yml registers the result and its
      # own changed_when reads `timesyncd_start.enabled` /
      # `timesyncd_start.state` directly; with only the nested `status`
      # dict present those failed with "object of type 'dict' has no
      # attribute 'enabled'" while ansible-playbook ran the same
      # task fine (round 903000).
      result_enabled : Bool? = nil
      if enabled
        is_enabled = enabled?(name_for_active || raise "systemd: name is required")
        should_enable = true?(enabled)
        result_enabled = is_enabled

        if should_enable && !is_enabled
          result_enabled = should_enable
          if @check_mode
            messages << "Would enable #{name}"
            changed = true
          else
            enable_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{force_flag} enable #{shell_single_quote(name.to_s)}")
            if enable_result[:exit_code] == 0
              messages << "Unit enabled"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Unable to enable service #{name}: #{enable_result[:stdout]}#{enable_result[:stderr]}"
              )
            end
          end
        elsif !should_enable && is_enabled
          if @check_mode
            messages << "Would disable #{name}"
            changed = true
          else
            disable_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{force_flag} disable #{shell_single_quote(name.to_s)}")
            if disable_result[:exit_code] == 0
              messages << "Unit disabled"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Unable to disable service #{name}: #{disable_result[:stdout]}#{disable_result[:stderr]}"
              )
            end
          end
        end
      end

      result_state : String? = nil
      if state && name_for_active
        # real bails out when `systemctl show` yields no ActiveState (e.g. no
        # systemd running), reporting whatever properties it did get
        probe = systemctl_show(name_for_active)
        unless probe.has_key?("ActiveState")
          return PluginResult.new(changed: false, failed: true, msg: "Service is in unknown state",
            status: JSON.parse(probe.to_json))
        end
        is_running = active?(name_for_active)
        result_state = state

        case state
        when "started"
          unless is_running
            if @check_mode
              messages << "Would start #{name}"
              changed = true
            else
              start_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{no_block_flag} start #{shell_single_quote(name.to_s)}")
              if start_result[:exit_code] == 0
                messages << "Unit started"
                changed = true
              else
                return PluginResult.new(
                  changed: false,
                  failed: true,
                  msg: "Unable to start service #{name}: #{start_result[:stderr]}"
                )
              end
            end
          end
        when "stopped"
          if is_running
            if @check_mode
              messages << "Would stop #{name}"
              changed = true
            else
              stop_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{no_block_flag} stop #{shell_single_quote(name.to_s)}")
              if stop_result[:exit_code] == 0
                messages << "Unit stopped"
                changed = true
              else
                return PluginResult.new(
                  changed: false,
                  failed: true,
                  msg: "Unable to stop service #{name}: #{stop_result[:stderr]}"
                )
              end
            end
          end
        when "restarted"
          result_state = "started"
          if @check_mode
            messages << "Would restart #{name}"
            changed = true
          else
            # Ansible picks the state-change verb by the unit's CURRENT
            # state (systemd_service.py's state block: for restarted,
            # `if not is_running_service(...): action = 'start'` - so an
            # INACTIVE unit gets `systemctl start`, never `restart` - else
            # `action = state[:-2]`). Same selection the `reloaded` branch
            # below already implements. Found live (systemd-repro container,
            # Type=oneshot unit failing at start): an inactive unit's failed
            # restart must report Ansible's "Unable to start service
            # ..." wording, which also requires the `start` verb, not just
            # the message.
            action = is_running ? "restart" : "start"
            restart_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{no_block_flag} #{action} #{shell_single_quote(name.to_s)}")
            if restart_result[:exit_code] == 0
              messages << "Unit restarted"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Unable to #{action} service #{name}: #{restart_result[:stderr]}"
              )
            end
          end
        when "reloaded"
          result_state = "started"
          # Ansible's systemd module: `state: reloaded` reloads a
          # RUNNING service but STARTS an inactive one (its own state
          # block: for restarted/reloaded, `if not is_running_service(
          # ...) action = 'start'` - ActiveState not in active/activating
          # means start, else the reload). Plain `systemctl reload` of an
          # inactive unit fails "is not active, cannot reload".
          # mdsketch.teleport's own "Reload_Teleport" handler
          # (`ansible.builtin.systemd: {name: teleport, state: reloaded}`)
          # on a fresh install exposed it: the unit file was created in
          # the same play and the service had never started, so real
          # Ansible started it, while krikri failed the handler. Same
          # semantics plugins/service.cr already implements for the
          # `service` module's `state: reloaded` (its 0.9.x nginxinc.nginx
          # fix) - separate plugins, so the fix didn't carry over here
          # automatically.
          if @check_mode
            messages << (is_running ? "Would reload #{name}" : "Would start #{name}")
            changed = true
          elsif !is_running
            start_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{no_block_flag} start #{shell_single_quote(name.to_s)}")
            if start_result[:exit_code] == 0
              messages << "Unit started"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Unable to start service #{name}: #{start_result[:stderr]}"
              )
            end
          else
            reload_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag}#{no_block_flag} reload #{shell_single_quote(name.to_s)}")
            if reload_result[:exit_code] == 0
              messages << "Unit reloaded"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Unable to reload service #{name}: #{reload_result[:stderr]}"
              )
            end
          end
        else
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Invalid state: #{state}. Must be started, stopped, restarted, or reloaded"
          )
        end
      end

      msg = messages.empty? ? "No changes needed" : messages.join(", ")
      if @check_mode && !messages.empty?
        msg += " (check mode)"
      end

      # `status:` - Ansible's systemd module always populates this
      # (from `systemctl show <name>`, every KEY=VALUE property verbatim)
      # whenever a unit `name:` is given, independent of what state:/
      # enabled:/masked: management was also requested - a query-only
      # task (`systemd_service: {name: foo.target}`, no other params) is
      # a completely normal, real usage (konstruktoid-hardening's own
      # "Get ctrl-alt-del.target information" does exactly this, then a
      # later task reads `.status.FragmentPath` from the registered
      # result). Previously never populated at all, so `.status.
      # anything` always resolved to undefined - which then rendered as
      # the literal string "undefined" wherever it was used as a
      # path/value, not merely "empty".
      status = name ? systemctl_show(name) : Hash(String, String).new

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        status: status,
        name: name,
        # Ansible 2.19.11 registered systemd result (live-verified, started
        # changed and unchanged identical): name, changed, status, state,
        # failed; with enabled: given, enabled lands between status and
        # state (name, changed, status, enabled, state, ansible_facts,
        # failed, warnings). msg is krikri-only and trails the pins.
        key_order: ["name", "changed", "status", "enabled", "state"]
      )
      result.extra["enabled"] = JSON.parse(result_enabled.to_json) unless result_enabled.nil?
      result.extra["state"] = JSON.parse(result_state.to_json) unless result_state.nil?
      result
    end

    # Runs `systemctl show <name>` and parses its `KEY=VALUE` lines
    # (one per real systemd unit property - ActiveState, FragmentPath,
    # UnitFileState, etc.) into a plain string-keyed hash, matching
    # what Ansible's systemd module exposes as `.status`.
    private def systemctl_show(name : String) : Hash(String, String)
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} show #{shell_single_quote(name.to_s)}")
      status = Hash(String, String).new
      result[:stdout].each_line do |line|
        key, sep, value = line.partition('=')
        status[key] = value if sep == "="
      end
      status
    end

    # Whether the unit is currently active (running).
    #
    # `systemctl is-active` only exits 0 for ActiveState=active - a unit
    # that's `activating`/`auto-restart` (e.g. crash-looping under
    # Restart=on-failure, same class as plugins/service.cr's 0.9.648 fix -
    # a separate plugin, separate check, so the fix didn't carry over here
    # automatically) exits non-zero even though Ansible's systemd
    # module already considers it "running" and won't reissue `start` for
    # it. Read the raw ActiveState instead so a crash-looping unit doesn't
    # get restarted (and reported changed) on every single run. Found
    # benchmarking cloudalchemy.cortex's "ensure cortex all-in-one service
    # is started and enabled" task.
    private def active?(name : String) : Bool
      active_state = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} show #{shell_single_quote(name.to_s)} --property=ActiveState --value 2>/dev/null")[:stdout].to_s.strip
      {"active", "activating"}.includes?(active_state)
    end

    # Whether the unit is enabled on boot.
    # See `SystemdEnabledState.enabled_from_is_enabled?`'s own comment
    # (`src/krikri/plugin_helpers/systemd_enabled_state.cr`) for the real
    # semantics this replicates, `-l` and all - factored into its own
    # file (like `AptLockRetry`) so a spec can require the pure decision
    # logic without a real `systemctl` or this plugin's STDIN entry point.
    private def enabled?(name : String) : Bool
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} is-enabled #{shell_single_quote(name.to_s)} -l 2>/dev/null")
      SystemdEnabledState.enabled_from_is_enabled?(result[:exit_code], result[:stdout])
    end

    # Whether the unit is masked.
    private def masked?(name : String) : Bool
      # Masked units show the literal word "masked" from `is-enabled`.
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} is-enabled #{shell_single_quote(name.to_s)} 2>/dev/null")
      result[:stdout].strip == "masked"
    end

    # `scope: user|global|system` (Ansible's own `systemd_service`/
    # `systemd` parameter) - selects which systemd MANAGER instance every
    # `systemctl` invocation targets (`--user` for the invoking user's own
    # session manager, `--global` for that user's not-yet-logged-in
    # default, plain/no flag - "system" - for the usual machine-wide one).
    # Entirely unhandled before: every systemctl call here always hit the
    # system manager regardless of `scope:`, so a `scope: user` task -
    # exactly the shape a rootless-Docker/Podman role's own "enable my
    # user unit" task uses - checked/managed a SYSTEM unit of the same
    # name (usually absent) instead of the real per-user one under
    # `~/.config/systemd/user/`, either doing nothing or reporting "unit
    # file does not exist" for a unit that's actually there. Found live
    # via konstruktoid.docker_rootless's own "Enable and start Docker"
    # (`scope: user`) - Ansible enables/starts the user-session
    # docker.service; this engine failed outright ("Unit file docker.
    # service does not exist"), looking at the SYSTEM unit namespace.
    private def scope_flag : String
      case @params["scope"]?
      when "user"   then " --user"
      when "global" then " --global"
      else               ""
      end
    end

    # The stderr shapes a `systemctl` probe produces when it cannot reach
    # a service manager at all - the failure Ansible's module re-raises
    # through its bare `run_command(systemctl, check_rc=True)` fallback:
    # - system scope without systemd: "System has not been booted with
    #   systemd as init system (PID 1). Can't operate." (+ the
    #   "Failed to connect to system scope bus via local transport" tail);
    # - user scope without a user bus: "Failed to connect to user scope
    #   bus via local transport: No such file or directory";
    # - ANY scope:global verb systemctl does not support: "--global is
    #   not supported for this operation." (Ansible fails a scope: global
    #   task on a healthy systemd host the same way - every command the
    #   module runs rejects the flag);
    # - the older "Failed to connect to bus:" wording some systemctl
    #   builds emit for the same condition.
    private def no_bus_failure?(stderr : String) : Bool
      stderr.includes?("System has not been booted with systemd") ||
        stderr.includes?("scope bus via local transport") ||
        stderr.includes?("Failed to connect to bus") ||
        stderr.includes?("--global is not supported for this operation")
    end

    # `systemctl --user` needs a reachable per-user D-Bus session, which
    # it finds via `$XDG_RUNTIME_DIR` (conventionally `/run/user/<uid>`) -
    # Ansible's systemd module sets this itself whenever `scope:
    # user` is given and the caller hasn't already set it (see its own
    # `home = expanduser("~")`/`XDG_RUNTIME_DIR` handling), precisely so
    # a `become_user:`'d task doesn't need its OWN separate `environment:
    # {XDG_RUNTIME_DIR: ...}` block just to make `--user` reach the right
    # bus. `$(id -u)` (not a fixed uid: this plugin process already runs
    # AS the become_user by the time it execs `systemctl`, so its own
    # effective uid is exactly right) rather than looking up the task's
    # `become_user:` name here, which this plugin never even receives.
    # Missing entirely before - found via konstruktoid.docker_rootless's
    # own "Enable and start Docker" (`scope: user`, no `environment:` of
    # its own - only the ROOTFUL half of this role sets XDG_RUNTIME_DIR
    # explicitly): `--user` alone still failed ("Unit file docker.service
    # does not exist") without a reachable runtime dir to find the real
    # per-user bus, even though the unit file was genuinely already
    # installed under `~/.config/systemd/user/docker.service`.
    private def scope_env_prefix : String
      @params["scope"]? == "user" ? "XDG_RUNTIME_DIR=/run/user/$(id -u) " : ""
    end

    # Helper to convert string/bool to boolean
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SystemdPlugin.new(config)
plugin.run

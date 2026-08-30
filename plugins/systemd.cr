#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

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
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # name/daemon_reload/daemon_reexec all have real Ansible-documented
      # hyphenated aliases (`ansible-doc ansible.builtin.systemd`: name's
      # are service/unit; daemon_reload's is daemon-reload; daemon_
      # reexec's is daemon-reexec) - found via round171's buluma.gitea,
      # whose own "Systemctl daemon-reload" handler writes `daemon-
      # reload: true` (the alias spelling, not the canonical param name).
      # Previously only the canonical name was read, so this handler hit
      # the "no action" guard below and failed outright every time its
      # notifying task actually changed something, instead of running
      # the reload real ansible-playbook performs.
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
      # of running the reexec real ansible-playbook performs.
      daemon_reexec = true?(@params["daemon_reexec"]? || @params["daemon-reexec"]?)

      # Must have at least one action. Unlike `service`, name is optional
      # (a task may only want daemon_reload/daemon_reexec), so the "no
      # action" guard covers every meaningful request rather than the
      # name itself.
      unless name || state || enabled || masked || daemon_reload || daemon_reexec
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Must specify at least one of 'name', 'state', 'enabled', 'masked', 'daemon_reload', or 'daemon_reexec'"
        )
      end

      # systemctl only accepts units or unit paths; a bare name like
      # "nginx" is resolved by systemctl itself, so no normalization is
      # needed. But commands that need a unit require name present.
      if (state || enabled || masked) && name.nil?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Must specify 'name' when using 'state', 'enabled', or 'masked'"
        )
      end

      changed = false
      messages = [] of String

      # daemon_reload: no unit needed. Always actually runs the reload
      # (systemctl daemon-reload has no reliable "was anything stale"
      # signal to check first), but does NOT set changed - verified
      # against a real ansible-playbook run of dev-sec os_hardening's own
      # "Reload systemd" handler (`ansible.builtin.systemd: {daemon_reload:
      # true}`, no name:/state:), which reported `ok:` every time, never
      # `changed:`. Previously set changed: true unconditionally here,
      # so a handler notified only for its side effect (systemd picking
      # up a changed unit file) showed as "changed" on every run even
      # when nothing else in the task changed - real Ansible's own
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
              msg: "Failed to reload systemd daemon: #{reload_result[:stderr]}"
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
              msg: "Failed to re-execute systemd daemon: #{reexec_result[:stderr]}"
            )
          end
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
            mask_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} mask #{name}")
            if mask_result[:exit_code] == 0
              messages << "Unit masked"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to mask #{name}: #{mask_result[:stderr]}"
              )
            end
          end
        elsif !should_mask && is_masked
          if @check_mode
            messages << "Would unmask #{name}"
            changed = true
          else
            unmask_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} unmask #{name}")
            if unmask_result[:exit_code] == 0
              messages << "Unit unmasked"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to unmask #{name}: #{unmask_result[:stderr]}"
              )
            end
          end
        end
      end

      name_for_active = name

      # Enabled/disabled
      if enabled
        is_enabled = enabled?(name_for_active || raise "systemd: name is required")
        should_enable = true?(enabled)

        if should_enable && !is_enabled
          if @check_mode
            messages << "Would enable #{name}"
            changed = true
          else
            enable_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} enable #{name}")
            if enable_result[:exit_code] == 0
              messages << "Unit enabled"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to enable #{name}: #{enable_result[:stderr]}"
              )
            end
          end
        elsif !should_enable && is_enabled
          if @check_mode
            messages << "Would disable #{name}"
            changed = true
          else
            disable_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} disable #{name}")
            if disable_result[:exit_code] == 0
              messages << "Unit disabled"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to disable #{name}: #{disable_result[:stderr]}"
              )
            end
          end
        end
      end

      # State
      if state && name_for_active
        is_running = active?(name_for_active)

        case state
        when "started"
          unless is_running
            if @check_mode
              messages << "Would start #{name}"
              changed = true
            else
              start_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} start #{name}")
              if start_result[:exit_code] == 0
                messages << "Unit started"
                changed = true
              else
                return PluginResult.new(
                  changed: false,
                  failed: true,
                  msg: "Failed to start #{name}: #{start_result[:stderr]}"
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
              stop_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} stop #{name}")
              if stop_result[:exit_code] == 0
                messages << "Unit stopped"
                changed = true
              else
                return PluginResult.new(
                  changed: false,
                  failed: true,
                  msg: "Failed to stop #{name}: #{stop_result[:stderr]}"
                )
              end
            end
          end
        when "restarted"
          if @check_mode
            messages << "Would restart #{name}"
            changed = true
          else
            restart_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} restart #{name}")
            if restart_result[:exit_code] == 0
              messages << "Unit restarted"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to restart #{name}: #{restart_result[:stderr]}"
              )
            end
          end
        when "reloaded"
          if @check_mode
            messages << "Would reload #{name}"
            changed = true
          else
            reload_result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} reload #{name}")
            if reload_result[:exit_code] == 0
              messages << "Unit reloaded"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to reload #{name}: #{reload_result[:stderr]}"
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

      # `status:` - real Ansible's systemd module always populates this
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
      status = name ? systemctl_show(name) : nil

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        status: status
      )
    end

    # Runs `systemctl show <name>` and parses its `KEY=VALUE` lines
    # (one per real systemd unit property - ActiveState, FragmentPath,
    # UnitFileState, etc.) into a plain string-keyed hash, matching
    # what real Ansible's systemd module exposes as `.status`.
    private def systemctl_show(name : String) : Hash(String, String)
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} show #{name}")
      status = Hash(String, String).new
      result[:stdout].each_line do |line|
        key, sep, value = line.partition('=')
        status[key] = value if sep == "="
      end
      status
    end

    # Whether the unit is currently active (running).
    private def active?(name : String) : Bool
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} is-active #{name} 2>/dev/null")
      result[:exit_code] == 0
    end

    # Whether the unit is enabled on boot.
    private def enabled?(name : String) : Bool
      # `systemctl is-enabled` exits 0 when enabled, but exits non-zero for
      # "disabled", "masked", and "static" alike - so exit code alone can't
      # distinguish "disabled" from "static". Parse the output word
      # instead: only an explicit "enabled" word means boot-enabled.
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} is-enabled #{name} 2>/dev/null")
      output = result[:stdout].strip
      (result[:exit_code] == 0) && (output == "enabled")
    end

    # Whether the unit is masked.
    private def masked?(name : String) : Bool
      # Masked units show the literal word "masked" from `is-enabled`.
      result = remote_exec("#{scope_env_prefix}systemctl#{scope_flag} is-enabled #{name} 2>/dev/null")
      result[:stdout].strip == "masked"
    end

    # `scope: user|global|system` (real Ansible's own `systemd_service`/
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
    # (`scope: user`) - real Ansible enables/starts the user-session
    # docker.service; this engine failed outright ("Unit file docker.
    # service does not exist"), looking at the SYSTEM unit namespace.
    private def scope_flag : String
      case @params["scope"]?
      when "user"   then " --user"
      when "global" then " --global"
      else               ""
      end
    end

    # `systemctl --user` needs a reachable per-user D-Bus session, which
    # it finds via `$XDG_RUNTIME_DIR` (conventionally `/run/user/<uid>`) -
    # real Ansible's systemd module sets this itself whenever `scope:
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
    private def true?(value) : Bool
      return false if value.nil?
      value_str = value.to_s.downcase
      value_str == "true" || value_str == "yes" || value_str == "1"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SystemdPlugin.new(config)
plugin.run

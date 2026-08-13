#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
    property check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      name = @params["name"]?
      state = @params["state"]?
      enabled = @params["enabled"]?
      masked = @params["masked"]?
      daemon_reload = is_true?(@params["daemon_reload"]?)
      # daemon_reexec: yes/no - `systemctl daemon-reexec`, re-executing
      # systemd itself (distinct from daemon-reload). Entirely
      # unimplemented before - fell into the "no action" guard below,
      # found via robertdebock.mysql's own "Systemctl daemon-reexec"
      # handler (`ansible.builtin.systemd: {daemon_reexec: true}`, no
      # other params at all - round 18), which failed outright instead
      # of running the reexec real ansible-playbook performs.
      daemon_reexec = is_true?(@params["daemon_reexec"]?)

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
          reload_result = remote_exec("systemctl daemon-reload")
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
          reexec_result = remote_exec("systemctl daemon-reexec")
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
        should_mask = is_true?(masked)
        is_masked = masked?(name.not_nil!)

        if should_mask && !is_masked
          if @check_mode
            messages << "Would mask #{name}"
            changed = true
          else
            mask_result = remote_exec("systemctl mask #{name}")
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
            unmask_result = remote_exec("systemctl unmask #{name}")
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
        is_enabled = enabled?(name_for_active.not_nil!)
        should_enable = is_true?(enabled)

        if should_enable && !is_enabled
          if @check_mode
            messages << "Would enable #{name}"
            changed = true
          else
            enable_result = remote_exec("systemctl enable #{name}")
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
            disable_result = remote_exec("systemctl disable #{name}")
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
              start_result = remote_exec("systemctl start #{name}")
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
              stop_result = remote_exec("systemctl stop #{name}")
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
            restart_result = remote_exec("systemctl restart #{name}")
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
            reload_result = remote_exec("systemctl reload #{name}")
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
      result = remote_exec("systemctl show #{name}")
      status = Hash(String, String).new
      result[:stdout].each_line do |line|
        key, sep, value = line.partition('=')
        status[key] = value if sep == "="
      end
      status
    end

    # Whether the unit is currently active (running).
    private def active?(name : String) : Bool
      result = remote_exec("systemctl is-active #{name} 2>/dev/null")
      result[:exit_code] == 0
    end

    # Whether the unit is enabled on boot.
    private def enabled?(name : String) : Bool
      # `systemctl is-enabled` exits 0 when enabled, but exits non-zero for
      # "disabled", "masked", and "static" alike - so exit code alone can't
      # distinguish "disabled" from "static". Parse the output word
      # instead: only an explicit "enabled" word means boot-enabled.
      result = remote_exec("systemctl is-enabled #{name} 2>/dev/null")
      output = result[:stdout].strip
      (result[:exit_code] == 0) && (output == "enabled")
    end

    # Whether the unit is masked.
    private def masked?(name : String) : Bool
      # Masked units show the literal word "masked" from `is-enabled`.
      result = remote_exec("systemctl is-enabled #{name} 2>/dev/null")
      result[:stdout].strip == "masked"
    end

    # Helper to convert string/bool to boolean
    private def is_true?(value) : Bool
      return false if value.nil?
      value_str = value.to_s.downcase
      value_str == "true" || value_str == "yes" || value_str == "1"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::SystemdPlugin.new(config)
plugin.run

#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Service Plugin - Manage system services
  #
  # Parameters:
  #   name (required): Service name
  #   state (optional): started, stopped, restarted, reloaded
  #   enabled (optional): yes/no - enable on boot
  #   check_mode (optional): Dry-run mode
  #
  # Examples:
  #   service:
  #     name: nginx
  #     state: started
  #     enabled: yes
  class ServicePlugin < BasePlugin
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # Validate required parameters
      name = @params["name"]?
      unless name
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: name"
        )
      end

      state = @params["state"]?
      enabled = @params["enabled"]?

      # Must have at least one action
      unless state || enabled
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Must specify 'state' or 'enabled'"
        )
      end

      changed = false
      messages = [] of String

      # Handle enabled/disabled
      if enabled
        result = remote_exec("systemctl is-enabled #{name} 2>/dev/null")
        is_enabled = result[:exit_code] == 0

        should_enable = is_true?(enabled)

        if should_enable && !is_enabled
          if @check_mode
            messages << "Would enable #{name}"
            changed = true
          else
            enable_result = remote_exec("systemctl enable #{name}")
            if enable_result[:exit_code] == 0
              messages << "Service enabled"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to enable service: #{enable_result[:stderr]}"
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
              messages << "Service disabled"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to disable service: #{disable_result[:stderr]}"
              )
            end
          end
        end
      end

      # Handle state
      if state
        result = remote_exec("systemctl is-active #{name} 2>/dev/null")
        is_running = result[:exit_code] == 0

        case state
        when "started"
          if !is_running
            if @check_mode
              messages << "Would start #{name}"
              changed = true
            else
              start_result = remote_exec("systemctl start #{name}")
              if start_result[:exit_code] == 0
                messages << "Service started"
                changed = true
              else
                return PluginResult.new(
                  changed: false,
                  failed: true,
                  msg: "Failed to start service: #{start_result[:stderr]}"
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
                messages << "Service stopped"
                changed = true
              else
                return PluginResult.new(
                  changed: false,
                  failed: true,
                  msg: "Failed to stop service: #{stop_result[:stderr]}"
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
              messages << "Service restarted"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to restart service: #{restart_result[:stderr]}"
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
              messages << "Service reloaded"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to reload service: #{reload_result[:stderr]}"
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

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg
      )
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
plugin = CrystalPlay::ServicePlugin.new(config)
plugin.run

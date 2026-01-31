#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # APT Plugin - Debian/Ubuntu package management
  # 
  # Parameters:
  #   name (required): Package name
  #   state (optional): present, absent, latest (default: present)
  #   update_cache (optional): Update apt cache before operation
  #   cache_valid_time (optional): Cache is valid for this many seconds
  #   check_mode (optional): Dry-run mode
  #
  # Examples:
  #   apt:
  #     name: nginx
  #     state: present
  #     update_cache: yes
  class AptPlugin < BasePlugin
    property check_mode : Bool
    
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
      
      state = @params["state"]? || "present"
      update_cache = is_true?(@params["update_cache"]?)
      cache_valid_time = @params["cache_valid_time"]?.try(&.to_i) || 0
      
      changed = false
      messages = [] of String
      
      # Handle cache update
      if update_cache
        if should_update_cache?(cache_valid_time)
          if @check_mode
            messages << "Would update apt cache"
            changed = true
          else
            update_result = remote_exec("apt-get update")
            if update_result[:exit_code] == 0
              messages << "APT cache updated"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to update apt cache: #{update_result[:stderr]}"
              )
            end
          end
        end
      end
      
      # Check if package is installed
      check_result = remote_exec("dpkg -l #{name} 2>/dev/null | grep '^ii'")
      is_installed = check_result[:exit_code] == 0
      
      case state
      when "present"
        if is_installed
          messages << "Package #{name} already installed"
        else
          if @check_mode
            messages << "Would install #{name}"
            changed = true
          else
            install_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y #{name}")
            if install_result[:exit_code] == 0
              messages << "Package #{name} installed"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to install #{name}: #{install_result[:stderr]}",
                stdout: install_result[:stdout],
                stderr: install_result[:stderr]
              )
            end
          end
        end
      
      when "absent"
        if !is_installed
          messages << "Package #{name} not installed"
        else
          if @check_mode
            messages << "Would remove #{name}"
            changed = true
          else
            remove_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get remove -y #{name}")
            if remove_result[:exit_code] == 0
              messages << "Package #{name} removed"
              changed = true
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to remove #{name}: #{remove_result[:stderr]}"
              )
            end
          end
        end
      
      when "latest"
        if @check_mode
          # Check if upgrade is available
          check_upgrade = remote_exec("apt-get install --simulate #{name} 2>&1 | grep -i upgrade")
          if check_upgrade[:exit_code] == 0
            messages << "Would upgrade #{name} to latest"
            changed = true
          else
            messages << "Package #{name} already at latest version"
          end
        else
          upgrade_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade #{name}")
          # Check if package was actually upgraded
          was_upgraded = !upgrade_result[:stdout].includes?("already the newest version")
          if was_upgraded
            messages << "Package #{name} upgraded to latest"
            changed = true
          else
            messages << "Package #{name} already at latest version"
          end
        end
      
      else
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
      
      msg = messages.join(", ")
      if @check_mode && changed
        msg += " (check mode)"
      end
      
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg
      )
    end
    
    # Check if cache should be updated based on validity time
    private def should_update_cache?(cache_valid_time : Int32) : Bool
      return true if cache_valid_time == 0
      
      # Check last update time of apt lists
      result = remote_exec("stat -c %Y /var/lib/apt/lists/partial 2>/dev/null || echo 0")
      last_update = result[:stdout].strip.to_i
      current_time = Time.utc.to_unix
      
      age = current_time - last_update
      age > cache_valid_time
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
plugin = CrystalPlay::AptPlugin.new(config)
plugin.run

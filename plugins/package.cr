#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Package Plugin - OS-agnostic package management
  # 
  # Auto-detects package manager (dnf, yum, apt) and delegates
  # 
  # Parameters:
  #   name (required): Package name
  #   state (optional): present, absent, latest (default: present)
  #   check_mode (optional): Dry-run mode
  #
  # Examples:
  #   package:
  #     name: nginx
  #     state: present
  class PackagePlugin < BasePlugin
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

      # `name: "{{ some_list_var }}"` templates a *list* var through a
      # plain `{{ }}` substitution - since @params values are always
      # String, that renders as the var's JSON form (`["systemd"]`), not
      # a bare name. Passed straight through into `apt-get install -y
      # #{name}`/`dpkg -l #{name}` unparsed, this used to send apt the
      # literal text `["systemd"]` (brackets and quotes included) as a
      # single malformed package spec - apt's own confused response to
      # that was "you have held broken packages", nothing to do with any
      # real package hold. Space-joining a parsed JSON array here (apt-
      # get/dpkg -l both accept multiple space-separated names as
      # distinct arguments) fixes the common single/short list case this
      # simpler OS-agnostic module was already scoped to; per-package
      # idempotency for longer multi-package lists remains an existing
      # limitation of this module's single-name-string design (apt.cr/
      # dnf.cr's own richer per-package handling doesn't apply here).
      trimmed = name.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        name = parsed.join(" ") if parsed
      end

      state = @params["state"]? || "present"
      
      # Detect package manager
      package_manager = detect_package_manager()
      
      unless package_manager
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not detect package manager (tried: dnf, yum, apt)"
        )
      end
      
      # Delegate to appropriate package manager
      case package_manager
      when "dnf", "yum"
        handle_dnf(name, state)
      when "apt"
        handle_apt(name, state)
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported package manager: #{package_manager}"
        )
      end
    end
    
    # Detect which package manager is available
    private def detect_package_manager() : String?
      # Try dnf first (newer)
      result = remote_exec("which dnf 2>/dev/null")
      return "dnf" if result[:exit_code] == 0
      
      # Try yum (older RHEL/CentOS)
      result = remote_exec("which yum 2>/dev/null")
      return "yum" if result[:exit_code] == 0
      
      # Try apt (Debian/Ubuntu)
      result = remote_exec("which apt-get 2>/dev/null")
      return "apt" if result[:exit_code] == 0
      
      nil
    end
    
    # Handle DNF/YUM package management
    private def handle_dnf(name : String, state : String) : PluginResult
      # Check if package is installed
      check_result = remote_exec("rpm -q #{name}")
      is_installed = check_result[:exit_code] == 0
      
      case state
      when "present"
        if is_installed
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Package #{name} already installed"
          )
        else
          if @check_mode
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Would install #{name} (check mode)"
            )
          end
          
          install_result = remote_exec("dnf install -y #{name} || yum install -y #{name}")
          if install_result[:exit_code] == 0
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Package #{name} installed"
            )
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to install #{name}: #{install_result[:stderr]}",
              stderr: install_result[:stderr]
            )
          end
        end
      
      when "absent"
        if !is_installed
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Package #{name} not installed"
          )
        else
          if @check_mode
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Would remove #{name} (check mode)"
            )
          end
          
          remove_result = remote_exec("dnf remove -y #{name} || yum remove -y #{name}")
          if remove_result[:exit_code] == 0
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Package #{name} removed"
            )
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to remove #{name}: #{remove_result[:stderr]}"
            )
          end
        end
      
      when "latest"
        if @check_mode
          check_update = remote_exec("dnf check-update #{name} || yum check-update #{name}")
          # check-update returns 100 if updates are available
          if check_update[:exit_code] == 100
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Would update #{name} to latest (check mode)"
            )
          else
            return PluginResult.new(
              changed: false,
              failed: false,
              msg: "Package #{name} already at latest version (check mode)"
            )
          end
        end
        
        update_result = remote_exec("dnf install -y #{name} || yum install -y #{name}")
        # Check if actually updated
        was_updated = !update_result[:stdout].includes?("Nothing to do")
        
        return PluginResult.new(
          changed: was_updated,
          failed: false,
          msg: was_updated ? "Package #{name} updated to latest" : "Package #{name} already at latest version"
        )
      
      else
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
    end
    
    # Handle APT package management
    private def handle_apt(name : String, state : String) : PluginResult
      # Check if package is installed
      check_result = remote_exec("dpkg -l #{name} 2>/dev/null | grep '^ii'")
      is_installed = check_result[:exit_code] == 0
      
      case state
      when "present"
        if is_installed
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Package #{name} already installed"
          )
        else
          if @check_mode
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Would install #{name} (check mode)"
            )
          end
          
          install_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y #{name}")
          if install_result[:exit_code] == 0
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Package #{name} installed"
            )
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to install #{name}: #{install_result[:stderr]}",
              stderr: install_result[:stderr]
            )
          end
        end
      
      when "absent"
        if !is_installed
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Package #{name} not installed"
          )
        else
          if @check_mode
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Would remove #{name} (check mode)"
            )
          end
          
          remove_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get remove -y #{name}")
          if remove_result[:exit_code] == 0
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Package #{name} removed"
            )
          else
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to remove #{name}: #{remove_result[:stderr]}"
            )
          end
        end
      
      when "latest"
        if @check_mode
          check_upgrade = remote_exec("apt-get install --simulate #{name} 2>&1 | grep -i upgrade")
          if check_upgrade[:exit_code] == 0
            return PluginResult.new(
              changed: true,
              failed: false,
              msg: "Would upgrade #{name} to latest (check mode)"
            )
          else
            return PluginResult.new(
              changed: false,
              failed: false,
              msg: "Package #{name} already at latest version (check mode)"
            )
          end
        end
        
        upgrade_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade #{name}")
        was_upgraded = !upgrade_result[:stdout].includes?("already the newest version")
        
        return PluginResult.new(
          changed: was_upgraded,
          failed: false,
          msg: was_upgraded ? "Package #{name} upgraded to latest" : "Package #{name} already at latest version"
        )
      
      else
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
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
plugin = CrystalPlay::PackagePlugin.new(config)
plugin.run

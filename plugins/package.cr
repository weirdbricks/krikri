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
      # Validate required parameters. `name:` isn't required when
      # update_cache: true is given with nothing else - real Ansible's
      # own package:/apt: modules allow a cache-refresh-only invocation,
      # a real idiom (ansible-community.ansible-vault's own "Update
      # package cache" task does exactly this: `package: {update_cache:
      # true}`, no name: at all). Matches apt.cr's own identical
      # exception for the same case.
      name = @params["name"]?
      update_cache = is_true?(@params["update_cache"]?)
      unless name
        return update_cache ? update_cache_only : PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: name (unless using update_cache)"
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
      elsif trimmed.includes?(',')
        # A *literal* YAML list (`name: [tuned, python3-configobj]`,
        # unlike the templated-var JSON-bracket case above) is stringified
        # comma-joined by the parser - "the format every existing
        # plugin's list params already expect" per playbook_parser.cr's
        # own stringify_value, but apt-get/dpkg -l/rpm -q all need space-
        # separated names, not comma-separated (a real single package
        # name never contains a comma, so this can't misfire).
        name = trimmed.split(',').map(&.strip).reject(&.empty?).join(" ")
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
    
    # `name:` may be several space-separated package names (this module's
    # own space-joining of a templated list var - see the JSON-array
    # handling in #execute above). True only if *every* one is installed,
    # not merely one of them.
    private def all_packages_installed?(name : String, & : String -> Bool) : Bool
      name.split(' ').reject(&.empty?).all? { |pkg| yield pkg }
    end

    # update_cache: true with no name: - just refresh the package
    # manager's own index, matching real Ansible's own cache-refresh-
    # only idiom for package:/apt:.
    private def update_cache_only : PluginResult
      package_manager = detect_package_manager()
      unless package_manager
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not detect package manager (tried: dnf, yum, apt)"
        )
      end

      command = case package_manager
                when "dnf" then "dnf makecache"
                when "yum" then "yum makecache"
                else            "apt-get update"
                end

      result = remote_exec(command)
      if result[:exit_code] == 0
        PluginResult.new(changed: true, failed: false, msg: "Package cache updated")
      else
        PluginResult.new(changed: false, failed: true, msg: "Failed to update package cache: #{result[:stderr]}")
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
      # Check if package is installed - each name checked individually
      # (not `rpm -q #{name}` as one combined call) so a multi-package
      # `name:` (this module's own space-joined list, from a templated
      # list var) can't have one installed package mask another that
      # isn't: linux-system-roles/kernel_settings' `name: "tuned
      # python3-configobj"` previously read as "installed" the moment
      # *either* package matched.
      is_installed = all_packages_installed?(name) { |pkg| remote_exec("rpm -q #{pkg}")[:exit_code] == 0 }
      
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
      # Check if package is installed - each name checked individually
      # (see handle_dnf's own comment for why: a single combined `dpkg -l
      # pkg1 pkg2 | grep '^ii'` matches as soon as *any* one of them is
      # installed, not all of them).
      is_installed = all_packages_installed?(name) { |pkg| remote_exec("dpkg -l #{pkg} 2>/dev/null | grep '^ii'")[:exit_code] == 0 }
      
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

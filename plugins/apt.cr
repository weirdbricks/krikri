#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # APT Plugin - Debian/Ubuntu package management
  #
  # Parameters:
  #   name (optional): Package name or list of packages
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
    property check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # Get state (default: present)
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

      # Get package name(s) - can be optional if just updating cache, or
      # running autoremove/autoclean/clean (real Ansible's apt module
      # supports all four with no `name:` at all - konstruktoid-hardening's
      # own "Run apt-get autoremove"/"Run apt-get clean" handlers do
      # exactly `autoremove: true` and `autoclean: true, clean: true`
      # with no name).
      name_param = @params["name"]?
      autoremove = is_true?(@params["autoremove"]?)
      autoclean = is_true?(@params["autoclean"]?)
      clean = is_true?(@params["clean"]?)

      if autoremove || autoclean || clean
        {
          {autoremove, "apt-get -y autoremove", "packages removed"},
          {autoclean, "apt-get -y autoclean", "autocleaned"},
          {clean, "apt-get clean", "cache cleaned"},
        }.each do |(enabled, cmd, label)|
          next unless enabled

          if @check_mode
            messages << "Would run: #{cmd}"
            changed = true
            next
          end

          result = remote_exec(cmd)
          if result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true, msg: "#{cmd} failed: #{result[:stderr]}")
          end

          # `autoremove` prints apt's own "nothing to do" summary line
          # when there's genuinely nothing to remove; `autoclean`/`clean`
          # print nothing at all when the cache was already clean - both
          # signal "unchanged" as empty/no-op output, matching real
          # Ansible's apt module's own changed: for these flags.
          did_something = if cmd.includes?("autoremove")
                             !result[:stdout].includes?("0 upgraded, 0 newly installed, 0 to remove")
                           else
                             !result[:stdout].strip.empty?
                           end

          if did_something
            changed = true
            messages << label
          end
        end
      end

      # If no package name provided, just return cache update result
      unless name_param
        if update_cache || autoremove || autoclean || clean
          msg = messages.empty? ? "Cache up to date" : messages.join(", ")
          return PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg
          )
        else
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Missing required parameter: name (unless using update_cache)"
          )
        end
      end

      # Parse package names - handle both single string and comma-separated list
      packages = parse_package_names(name_param)

      # Process each package based on state. Real Ansible's own apt
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
        handle_install(packages, messages, false)
      when "absent"
        handle_remove(packages, messages, false)
      when "latest"
        handle_latest(packages, messages, false)
      else
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
    end

    # Parse package names from parameter (handles comma-separated or single)
    private def parse_package_names(name_param : String) : Array(String)
      # Split by comma and clean up whitespace
      packages = name_param.split(",").map(&.strip).reject(&.empty?)
      packages
    end

    # Handle installing packages
    private def handle_install(packages : Array(String), messages : Array(String), changed : Bool) : PluginResult
      to_install = [] of String
      already_installed = [] of String

      # Check which packages need installation
      packages.each do |pkg|
        check_result = remote_exec("dpkg -l #{pkg} 2>/dev/null | grep '^ii'")
        if check_result[:exit_code] == 0
          already_installed << pkg
        else
          to_install << pkg
        end
      end

      # Install packages that aren't already installed
      unless to_install.empty?
        if @check_mode
          messages << "Would install #{to_install.join(", ")}"
          changed = true
        else
          pkg_list = to_install.join(" ")
          install_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y #{pkg_list}")
          if install_result[:exit_code] == 0
            messages << "Package#{to_install.size > 1 ? "s" : ""} #{to_install.join(", ")} installed"
            changed = true
          else
            return PluginResult.new(
              changed: changed,
              failed: true,
              msg: "Failed to install #{to_install.join(", ")}: #{install_result[:stderr]}",
              stdout: install_result[:stdout],
              stderr: install_result[:stderr]
            )
          end
        end
      end

      # Report already installed packages
      unless already_installed.empty?
        messages << "Package#{already_installed.size > 1 ? "s" : ""} #{already_installed.join(", ")} already installed"
      end

      msg = messages.empty? ? "No changes needed" : messages.join(", ")
      if @check_mode && changed
        msg += " (check mode)"
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg
      )
    end

    # Handle removing packages
    private def handle_remove(packages : Array(String), messages : Array(String), changed : Bool) : PluginResult
      to_remove = [] of String
      already_absent = [] of String

      # Check which packages need removal
      packages.each do |pkg|
        check_result = remote_exec("dpkg -l #{pkg} 2>/dev/null | grep '^ii'")
        if check_result[:exit_code] == 0
          to_remove << pkg
        else
          already_absent << pkg
        end
      end

      # Remove packages that are installed
      unless to_remove.empty?
        if @check_mode
          messages << "Would remove #{to_remove.join(", ")}"
          changed = true
        else
          pkg_list = to_remove.join(" ")
          remove_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get remove -y #{pkg_list}")
          if remove_result[:exit_code] == 0
            messages << "Package#{to_remove.size > 1 ? "s" : ""} #{to_remove.join(", ")} removed"
            changed = true
          else
            return PluginResult.new(
              changed: changed,
              failed: true,
              msg: "Failed to remove #{to_remove.join(", ")}: #{remove_result[:stderr]}"
            )
          end
        end
      end

      # Report already absent packages
      unless already_absent.empty?
        messages << "Package#{already_absent.size > 1 ? "s" : ""} #{already_absent.join(", ")} not installed"
      end

      msg = messages.empty? ? "No changes needed" : messages.join(", ")
      if @check_mode && changed
        msg += " (check mode)"
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg
      )
    end

    # Handle upgrading packages to latest
    private def handle_latest(packages : Array(String), messages : Array(String), changed : Bool) : PluginResult
      if @check_mode
        # Check if any upgrades are available
        check_cmds = packages.map { |pkg| "apt-get install --simulate #{pkg} 2>&1 | grep -i upgrade" }
        check_result = remote_exec(check_cmds.join(" || "))
        if check_result[:exit_code] == 0
          messages << "Would upgrade #{packages.join(", ")} to latest"
          changed = true
        else
          messages << "Package#{packages.size > 1 ? "s" : ""} #{packages.join(", ")} already at latest version"
        end
      else
        pkg_list = packages.join(" ")
        upgrade_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade #{pkg_list}")

        # Check if anything was actually upgraded
        was_upgraded = !upgrade_result[:stdout].includes?("already the newest version")
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

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

      # `upgrade: safe|yes|dist|full` with no `name:` (konstruktoid-
      # hardening's own "Run apt upgrade" task, `upgrade: safe`) - real
      # Ansible's apt module maps safe/yes to a plain `apt-get upgrade`
      # and dist/full to `apt-get dist-upgrade`. The task registers this
      # result and computes its own `changed_when` from `.stdout` (`'0
      # upgraded, 0 newly installed, 0 to remove' not in
      # apt_upgrade_response.stdout`), so the raw command output has to
      # actually reach the registered var's `stdout` field, not just
      # inform `changed`/`msg` here - passed through via the `stdout:`
      # kwarg the same way the package-install path below already does.
      upgrade = @params["upgrade"]?
      upgrade_stdout = ""
      if upgrade
        dist = upgrade == "dist" || upgrade == "full"
        cmd = dist ? "apt-get -y dist-upgrade" : "apt-get -y upgrade"

        if @check_mode
          messages << "Would run: #{cmd}"
          changed = true
        else
          result = remote_exec(cmd)
          if result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true, msg: "#{cmd} failed: #{result[:stderr]}", stdout: result[:stdout], stderr: result[:stderr])
          end

          upgrade_stdout = result[:stdout]
          unless result[:stdout].includes?("0 upgraded, 0 newly installed, 0 to remove")
            changed = true
          end
          messages << result[:stdout]
        end
      end

      # If no package name provided, just return cache update result
      unless name_param
        if update_cache || autoremove || autoclean || clean || upgrade
          msg = messages.empty? ? "Cache up to date" : messages.join(", ")
          return PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: upgrade_stdout
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

    # Parse package names from parameter (handles comma-separated, single,
    # or a JSON-array-shaped string).
    private def parse_package_names(name_param : String) : Array(String)
      # `name: "{{ packages_debian }}"` (konstruktoid-hardening's own
      # "Debian family package installation" task) templates a *list*
      # var through a plain `{{ }}` substitution - since @params values
      # are always String, the substitutor's own format_value renders an
      # Array as its JSON form (`["acct","apparmor-profiles",...]`), not
      # a bare comma-joined string. Splitting that on "," (the plain
      # comma-separated case below) left the brackets/quotes stuck to
      # the first and last entries ("[acct", "wamerican]"), which apt
      # then rejected outright as invalid package names. Detected here
      # and parsed as real JSON instead.
      trimmed = name_param.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        return parsed if parsed
      end

      # Split by comma and clean up whitespace
      packages = name_param.split(",").map(&.strip).reject(&.empty?)
      packages
    end

    # Real Ansible's apt module supports real apt's own `name=version`
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

    # Parses the version column (3rd whitespace-separated field) out of
    # a `dpkg -l <pkg> | grep '^ii'` line, e.g. "ii  rabbitmq-server
    # 3.12.2-1  amd64  ...".
    private def installed_version(dpkg_line : String) : String?
      dpkg_line.split(/\s+/)[2]?
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

    # Handle installing packages
    private def handle_install(packages : Array(String), messages : Array(String), changed : Bool) : PluginResult
      to_install = [] of String
      already_installed = [] of String

      # Check which packages need installation
      packages.each do |pkg|
        base_name, pinned_version = split_name_version(pkg)
        check_result = remote_exec("dpkg -l #{base_name} 2>/dev/null | grep '^ii'")
        if check_result[:exit_code] == 0 && (pinned_version.nil? || installed_version(check_result[:stdout]) == pinned_version)
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
          install_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold #{pkg_list}")
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
            # shows "0 upgraded, 0 newly installed" - real Ansible's own
            # apt module (python-apt bindings, not this CLI-based
            # shell-out) correctly resolves the Provides: relationship
            # and reports changed: false here.
            if apt_summary_had_no_effect?(install_result[:stdout])
              messages << "Package#{to_install.size > 1 ? "s" : ""} #{to_install.join(", ")} already satisfied"
            else
              messages << "Package#{to_install.size > 1 ? "s" : ""} #{to_install.join(", ")} installed"
              changed = true
            end
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

      # Check which packages need removal - state: absent removes by
      # NAME regardless of any `=version` pin (matching real apt-get
      # remove semantics), so only the base name is checked here.
      packages.each do |pkg|
        base_name, _ = split_name_version(pkg)
        check_result = remote_exec("dpkg -l #{base_name} 2>/dev/null | grep '^ii'")
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
        # `--only-upgrade` skips a package that isn't ALREADY installed
        # entirely ("Skipping grafana, it is not installed and only
        # upgrades are requested" - exit 0, "0 upgraded, 0 newly
        # installed") - real Ansible's own state: latest installs a
        # not-yet-present package too (apt-get's plain `install` already
        # does both: fresh-install when absent, upgrade when present and
        # outdated), so this plugin's own `--only-upgrade` flag was
        # simply wrong. Real bug found benchmarking cloudalchemy.
        # grafana's own "Install Grafana" task (state: "{{ (grafana_
        # version == 'latest') | ternary('latest', 'present') }}") -
        # reported "changed: Package grafana upgraded to latest" while
        # the package was never actually installed at all.
        upgrade_result = remote_exec("DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold #{pkg_list}")

        # "N upgraded, M newly installed, ..." is apt's own reliable,
        # locale-stable summary line - checking for the English phrase
        # "already the newest version" (the previous approach) missed
        # the "not installed and only upgrades are requested" case
        # entirely (a different message, so the check wrongly concluded
        # something HAD changed).
        summary = upgrade_result[:stdout][/(\d+) upgraded, (\d+) newly installed/]?
        was_upgraded = summary ? summary.scan(/\d+/).map(&.[0].to_i).sum > 0 : upgrade_result[:exit_code] == 0
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

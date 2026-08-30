#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Yum plugin - manages packages with the `yum` command. Compatible with
  # Ansible's ansible.builtin.yum module - a near-duplicate of dnf.cr's
  # own DnfPlugin (see build.sh's own convention of one tiny compiled
  # binary per module rather than shared library code between them),
  # shelling `yum` instead of `dnf` throughout.
  #
  # Verified live against a Rocky 9.6 target, where `/usr/bin/yum` is
  # itself a symlink to `dnf-3` (the standard modern RHEL-family setup
  # since RHEL8/CentOS8) - the flags this builds (`--setopt=install_
  # weak_deps=False`, `--best`, `--allowerasing`) are real dnf options
  # forwarded straight through that symlink. NOT verified against a
  # genuinely dnf-less yum (RHEL6/7-era) target - those flags don't
  # exist on classic yum, and real ansible.builtin.yum's own module
  # internally detects and branches on which backend it's talking to,
  # which this does not replicate. No RHEL7-or-older Atlantic.net image
  # was available to verify that path this round.
  #

  # Supports key Ansible dnf module parameters:
  # - name: Package name(s), group (@group), URL, or local RPM file
  # - state: present, installed, absent, removed, latest
  # - enablerepo: Repository to enable for this operation
  # - disablerepo: Repository to disable for this operation
  # - disable_gpg_check: Disable GPG signature checking
  # - update_only: Only update packages, don't install new ones
  # - autoremove: Remove unneeded dependencies
  # - security: Only install security updates (with state=latest)
  # - bugfix: Only install bugfix updates (with state=latest)
  # - install_weak_deps: Install weak dependencies (default: true)
  # - skip_broken: Skip packages with broken dependencies
  # - allow_downgrade: Allow downgrading packages
  #
  # Examples:
  #   dnf:
  #     name: httpd
  #     state: present
  #
  #   dnf:
  #     name:
  #       - httpd
  #       - nginx
  #     state: latest
  #
  #   dnf:
  #     name: "@Development tools"
  #     state: present
  class YumPlugin < BasePlugin
    def execute : PluginResult
      # Parse package name(s)
      # Can be a string, array (via list parameter), or comma-separated
      names = parse_package_names

      # `name:` isn't required when `update_cache: true` is given with
      # nothing else - real Ansible's own yum: module allows a cache-
      # refresh-only invocation (robertdebock.rpmfusion's own "Yum
      # update cache" handler: `ansible.builtin.yum: {update_cache:
      # yes}`, no name: at all). Matches package.cr's own identical
      # exception for the generic package: module - never ported here
      # until this task's own "Missing required parameter: name"
      # failure surfaced it live on a Rocky 9.6 target.
      if early = early_result_for_empty_names(names)
        return early
      end

      # Get state (default: present) and normalize state aliases
      state = normalized_state

      # Validate state
      unless ["present", "absent", "latest"].includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end

      # Handle special cases: autoremove or upgrade-all without package name
      if special = special_case_result(names, state)
        return special
      end

      # Build DNF command options
      dnf_options = build_dnf_options

      # Process based on state
      case state
      when "present"
        handle_install(names, dnf_options)
      when "absent"
        handle_remove(names, dnf_options)
      when "latest"
        handle_update(names, dnf_options)
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unexpected state: #{state}"
        )
      end
    end

    # Result to return early when no package names were given: either a
    # cache-only refresh (with `update_cache: true`), or the missing-name
    # failure. Returns nil when names is non-empty.
    private def early_result_for_empty_names(names : Array(String)) : PluginResult?
      return nil unless names.empty?

      if true?(@params["update_cache"]?)
        result = remote_exec("yum makecache")
        # changed: false even on success - same fix as dnf.cr's
        # identical branch (see its own comment): real ansible-core's
        # dnf/yum module never reports changed for a cache-only
        # refresh. Found via round172's buluma.rpmfusion.
        return PluginResult.new(
          changed: false,
          failed: result[:exit_code] != 0,
          msg: result[:exit_code] == 0 ? "Package cache updated" : "Failed to update package cache: #{result[:stderr]}"
        )
      end

      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Missing required parameter: name"
      )
    end

    # Get state (default: present) with aliases normalized
    private def normalized_state : String
      state = @params["state"]? || "present"
      case state
      when "installed"
        "present"
      when "removed"
        "absent"
      else
        state
      end
    end

    # Handle special case: autoremove or upgrade-all with no package names
    private def special_case_result(names : Array(String), state : String) : PluginResult?
      return handle_autoremove if true?(@params["autoremove"]?) && names == ["*"]
      return handle_upgrade_all if names == ["*"] && state == "latest"
      nil
    end

    # Parse package names from various parameter formats
    private def parse_package_names : Array(String)
      names = names_from_name_param || [] of String

      # Try 'list' parameter (array of packages)
      if list_param = @params["list"]?
        begin
          list_names = JSON.parse(list_param).as_a.map(&.as_s)
          names.concat(list_names)
        rescue
          # If parsing fails, treat as single package
          names << list_param
        end
      end

      # Try free-form parameter
      if names.empty? && (raw_param = @params["_raw_params"]?)
        names = raw_param.split.reject(&.empty?)
      end

      names.uniq
    end

    # Parse the 'name' parameter (can be string or list) - `pkg:` is a
    # documented alias of `name:` for real Ansible's yum module, same
    # as dnf.cr's own identical fix. Returns nil when neither parameter
    # is present.
    private def names_from_name_param : Array(String)?
      name_param = @params["name"]? || @params["pkg"]?
      return unless name_param

      parsed_json = parse_name_param_as_json(name_param.strip)

      if parsed_json
        parsed_json
      elsif name_param.includes?(",")
        name_param.split(",").map(&.strip)
      else
        [name_param]
      end
    end

    # `name: "{{ some_list_var }}"` templates a *list* var through a
    # plain `{{ }}` substitution - since @params values are always
    # String, that renders as the var's JSON form (`["foo","bar"]`),
    # not a bare comma-joined string. Parsed as real JSON here rather
    # than falling into the comma-split below, which would otherwise
    # leave the brackets/quotes stuck to the first/last entries (see
    # apt.cr's own parse_package_names for the same bug, found via
    # konstruktoid-hardening's package installation task). Returns nil
    # when the trimmed value isn't a bracketed list or fails to parse.
    private def parse_name_param_as_json(trimmed : String) : Array(String)?
      return unless trimmed.starts_with?('[') && trimmed.ends_with?(']')

      begin
        Array(String).from_json(trimmed)
      rescue
        # A Python-repr list (single-quoted strings) isn't
        # valid JSON - same fallback as apt.cr's/package.cr's
        # own copies of this logic (see there for the full
        # rationale: a Jinja `{% if %}...{{ [list] }}...
        # {% endif %}` template idiom renders as Python's
        # `str(list)` form, not JSON). Proactive fix - not
        # yet caught live for dnf specifically, but the
        # exact same bug class already found independently
        # in two other plugins this way.
        begin
          Array(String).from_json(trimmed.gsub('\'', '"'))
        rescue
          nil
        end
      end
    end

    # See dnf.cr's identical helper for the full rationale - this plugin
    # shells out to the same underlying `dnf` binary on modern RHEL-family
    # hosts (yum is a dnf shim there), so it hits the same "Error: Unknown
    # repo: 'X'" hard-failure for an `enablerepo:` naming a repo that isn't
    # configured, where real ansible.builtin.yum's own dnf-API-based
    # implementation just warns and continues.
    private def remote_exec_tolerating_unknown_repo(cmd : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      result = remote_exec(cmd)
      if result[:exit_code] != 0 && (m = result[:stderr].match(/Unknown repo: '([^']+)'/))
        stripped_cmd = cmd.gsub("--enablerepo=#{m[1]}", "").gsub(/  +/, " ")
        return remote_exec_tolerating_unknown_repo(stripped_cmd) if stripped_cmd != cmd
      end
      result
    end

    # Build DNF command line options
    private def build_dnf_options : String
      options = [] of String

      # Always use -y for non-interactive
      options << "-y"

      # Enable/disable repos
      if enablerepo = @params["enablerepo"]?
        enablerepo.split(",").each do |repo|
          options << "--enablerepo=#{repo.strip}"
        end
      end

      if disablerepo = @params["disablerepo"]?
        disablerepo.split(",").each do |repo|
          options << "--disablerepo=#{repo.strip}"
        end
      end

      # GPG check - real ansible's dnf module explicitly sets BOTH
      # conf.gpgcheck AND conf.localpkg_gpgcheck to `not disable_gpg_check`
      # (verified in ansible-core's own dnf.py: "conf.localpkg_gpgcheck =
      # not disable_gpg_check"), overriding dnf's own actual default for
      # local/URL package installs, which is gpgcheck-OFF regardless of
      # the repo gpgcheck=1 setting in dnf.conf. Plain `--nogpgcheck` only
      # covers the repo-package path; without also forcing
      # `--setopt=localpkg_gpgcheck=1` here, a `name: https://.../foo.rpm`
      # install silently skipped signature verification (inherited dnf's
      # own default), diverging from real ansible-playbook which
      # correctly refuses an RPM whose signing key isn't imported. Found
      # benchmarking geerlingguy.selenium's "Install Chrome (if
      # configured, RedHat)" task (direct google-chrome-stable RPM URL,
      # no imported key) - real ansible failed with "Failed to validate
      # GPG signature", crystal-ansible installed it anyway.
      if true?(@params["disable_gpg_check"]?)
        options << "--nogpgcheck"
      else
        options << "--setopt=localpkg_gpgcheck=1"
      end

      # Security/bugfix updates
      if true?(@params["security"]?)
        options << "--security"
      end

      if true?(@params["bugfix"]?)
        options << "--bugfix"
      end

      # Weak dependencies
      if false?(@params["install_weak_deps"]?)
        options << "--setopt=install_weak_deps=False"
      end

      # Skip broken packages
      if true?(@params["skip_broken"]?)
        options << "--skip-broken"
      end

      # Allow downgrade
      if true?(@params["allow_downgrade"]?)
        options << "--allowerasing"
      end

      # Best (default in dnf, but explicit is good)
      options << "--best" unless true?(@params["skip_broken"]?)

      options.join(" ")
    end

    # Install packages
    private def handle_install(names : Array(String), options : String) : PluginResult
      # Check if update_only is set
      update_only = true?(@params["update_only"]?)

      classified = classify_install_packages(names, update_only)
      to_install = classified[:to_install]
      to_update = classified[:to_update]
      already_installed = classified[:already_installed]

      changed = false
      messages = [] of String
      all_output = [] of String

      # Install new packages
      unless to_install.empty?
        outcome = run_install_batch(to_install, options)
        all_output << outcome[:output]

        failure = outcome[:failure]
        return failure if failure

        changed ||= outcome[:changed]
        if message = outcome[:message]
          messages << message
        end
      end

      # Update packages (if update_only mode)
      unless to_update.empty?
        outcome = run_update_batch(to_update, options)
        all_output << outcome[:output]

        failure = outcome[:failure]
        return failure if failure

        changed ||= outcome[:changed]
        if message = outcome[:message]
          messages << message
        end
      end

      # Report already installed
      unless already_installed.empty?
        messages << "Already installed: #{already_installed.join(", ")}"
      end

      msg = messages.empty? ? "No changes needed" : messages.join("; ")

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        stdout: all_output.join("\n"),
        exit_code: 0
      )
    end

    # Classify each requested package into install/update/already-installed
    # buckets based on its current state and the update_only mode.
    private def classify_install_packages(names : Array(String), update_only : Bool) : NamedTuple(to_install: Array(String), to_update: Array(String), already_installed: Array(String))
      to_install = [] of String
      to_update = [] of String
      already_installed = [] of String

      names.each do |pkg|
        if package_group?(pkg)
          # For groups, always try to install (dnf handles idempotency)
          to_install << pkg
        elsif url_or_file?(pkg)
          # For URLs/files, always try to install
          to_install << pkg
        else
          # Check if package is installed
          if package_installed?(pkg)
            if update_only
              to_update << pkg
            else
              already_installed << pkg
            end
          else
            if update_only
              # Don't install new packages in update_only mode
              already_installed << pkg
            else
              to_install << pkg
            end
          end
        end
      end

      {to_install: to_install, to_update: to_update, already_installed: already_installed}
    end

    # Outcome of a batch install/update command: whether it changed
    # anything, an optional message, captured stdout, and a non-nil
    # failure result when the command itself failed.
    private alias BatchOutcome = NamedTuple(changed: Bool, message: String?, output: String, failure: PluginResult?)

    # Run `yum install` for the given packages and interpret its result
    private def run_install_batch(to_install : Array(String), options : String) : BatchOutcome
      pkg_list = to_install.map { |pth| quote_package(pth) }.join(" ")
      cmd = "yum install #{options} #{pkg_list}"

      result = remote_exec_tolerating_unknown_repo(cmd)

      if result[:exit_code] != 0
        return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to install packages",
          stdout: result[:stdout],
          stderr: result[:stderr],
          exit_code: result[:exit_code]
        )}
      end

      # A requested name can be a virtual package already satisfied
      # by something else installed - `package_installed?`'s own
      # `dnf list installed <name>` pre-check only ever looks up the
      # literal requested name, which a purely virtual/Provides:-
      # satisfied name never has its own `dnf list installed` entry
      # for, so it always fell through to "needs install" here. dnf
      # itself prints a literal "Nothing to do." and still exits 0
      # for that case (a genuine no-op), so trusting exit_code alone
      # always reported changed: true even when nothing happened -
      # same bug class already fixed in apt.cr/package.cr's own
      # apt-get install handling (apt_summary_had_no_effect?), which
      # this handler never got ported to since it's a separate
      # RPM-based code path.
      if result[:stdout].includes?("Nothing to do")
        {changed: false, message: "Package#{to_install.size > 1 ? "s" : ""} #{to_install.join(", ")} already satisfied", output: result[:stdout], failure: nil}
      else
        {changed: true, message: "Installed: #{to_install.join(", ")}", output: result[:stdout], failure: nil}
      end
    end

    # Run `yum update` for the given packages and interpret its result
    private def run_update_batch(to_update : Array(String), options : String) : BatchOutcome
      pkg_list = to_update.map { |pth| quote_package(pth) }.join(" ")
      cmd = "yum update #{options} #{pkg_list}"

      result = remote_exec_tolerating_unknown_repo(cmd)

      if result[:exit_code] != 0
        return {changed: false, message: nil, output: result[:stdout], failure: PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to update packages",
          stdout: result[:stdout],
          stderr: result[:stderr],
          exit_code: result[:exit_code]
        )}
      end

      # Check if anything was actually updated
      if result[:stdout].includes?("Upgraded:") || result[:stdout].includes?("Installed:")
        {changed: true, message: "Updated: #{to_update.join(", ")}", output: result[:stdout], failure: nil}
      else
        {changed: false, message: nil, output: result[:stdout], failure: nil}
      end
    end

    # Remove packages
    private def handle_remove(names : Array(String), options : String) : PluginResult
      to_remove = [] of String
      already_absent = [] of String

      # Check which packages need to be removed
      names.each do |pkg|
        if package_group?(pkg)
          # For groups, always try to remove (dnf handles if not installed)
          to_remove << pkg
        else
          if package_installed?(pkg)
            to_remove << pkg
          else
            already_absent << pkg
          end
        end
      end

      # Nothing to do
      if to_remove.empty?
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "All packages already absent",
          exit_code: 0
        )
      end

      # Build remove command
      autoremove_flag = true?(@params["autoremove"]?) ? "" : "--setopt=clean_requirements_on_remove=False"
      pkg_list = to_remove.map { |pth| quote_package(pth) }.join(" ")
      cmd = "yum remove #{options} #{autoremove_flag} #{pkg_list}"

      result = remote_exec_tolerating_unknown_repo(cmd)

      success = result[:exit_code] == 0

      if success
        msg_parts = ["Removed: #{to_remove.join(", ")}"]
        msg_parts << "Already absent: #{already_absent.join(", ")}" unless already_absent.empty?

        PluginResult.new(
          changed: true,
          failed: false,
          msg: msg_parts.join("; "),
          stdout: result[:stdout],
          exit_code: 0
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to remove packages",
          stdout: result[:stdout],
          stderr: result[:stderr],
          exit_code: result[:exit_code]
        )
      end
    end

    # Update packages to latest version
    private def handle_update(names : Array(String), options : String) : PluginResult
      pkg_list = names.map { |pth| quote_package(pth) }.join(" ")
      cmd = "yum update #{options} #{pkg_list}"

      result = remote_exec_tolerating_unknown_repo(cmd)

      success = result[:exit_code] == 0

      if success
        # Check if anything was actually updated
        changed = result[:stdout].includes?("Upgraded:") ||
                  result[:stdout].includes?("Installed:") ||
                  result[:stdout].includes?("Obsoleted:")

        msg = changed ? "Packages updated to latest version" : "Packages already at latest version"

        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          stdout: result[:stdout],
          exit_code: 0
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to update packages",
          stdout: result[:stdout],
          stderr: result[:stderr],
          exit_code: result[:exit_code]
        )
      end
    end

    # Upgrade all packages
    private def handle_upgrade_all : PluginResult
      options = build_dnf_options
      cmd = "yum upgrade #{options}"

      result = remote_exec_tolerating_unknown_repo(cmd)

      success = result[:exit_code] == 0

      if success
        changed = result[:stdout].includes?("Upgraded:") ||
                  result[:stdout].includes?("Installed:")

        msg = changed ? "System upgraded" : "All packages already up to date"

        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          stdout: result[:stdout],
          exit_code: 0
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to upgrade system",
          stdout: result[:stdout],
          stderr: result[:stderr],
          exit_code: result[:exit_code]
        )
      end
    end

    # Handle autoremove operation
    private def handle_autoremove : PluginResult
      options = build_dnf_options
      cmd = "yum autoremove #{options}"

      result = remote_exec_tolerating_unknown_repo(cmd)

      success = result[:exit_code] == 0

      if success
        changed = result[:stdout].includes?("Removed:")

        msg = changed ? "Removed unneeded packages" : "No unneeded packages to remove"

        PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          stdout: result[:stdout],
          exit_code: 0
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Autoremove failed",
          stdout: result[:stdout],
          stderr: result[:stderr],
          exit_code: result[:exit_code]
        )
      end
    end

    # Check if a package is installed
    private def package_installed?(name : String) : Bool
      # Strip version specifiers for checking
      base_name = name.split(/[<>=]/).first.strip

      # See dnf.cr's own identical fix/comment for the full story: try
      # a plain `rpm -q <name>` first (correctly matches both a bare
      # name and a NEVRA-style "name-version" specifier), falling back
      # to `--whatprovides` (a Provides:/capability lookup) only for a
      # VIRTUAL package name satisfied purely via another real
      # package's `Provides:` (e.g. RHEL 9's `php-json`, bundled into
      # `php-common` since PHP 8.0) - `--whatprovides` ALONE regresses
      # any version-pinned NEVRA name (`rpm -q --whatprovides
      # telegraf-1.18.2` fails even when that exact NEVRA is installed,
      # verified live), so both checks are needed, in this order.
      result = remote_exec("rpm -q #{base_name} 2>/dev/null")
      return true if result[:exit_code] == 0

      result = remote_exec("rpm -q --whatprovides #{base_name} 2>/dev/null")
      result[:exit_code] == 0
    end

    # Check if name is a package group (starts with @)
    private def package_group?(name : String) : Bool
      name.starts_with?("@")
    end

    # Check if name is a URL or file path
    private def url_or_file?(name : String) : Bool
      name.starts_with?("http://") ||
        name.starts_with?("https://") ||
        name.starts_with?("ftp://") ||
        name.starts_with?("/")
    end

    # Quote package name if it contains special characters
    private def quote_package(name : String) : String
      if name.includes?(" ") || name.includes?(">") || name.includes?("<")
        "'#{name}'"
      else
        name
      end
    end

    # Helper: Check if parameter is truthy
    private def true?(value : String?) : Bool
      return false unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end

    # Helper: Check if parameter is falsy
    private def false?(value : String?) : Bool
      return false unless value
      ["false", "no", "0", "off"].includes?(value.downcase)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::YumPlugin.new(config)
plugin.run

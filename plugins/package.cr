#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/apt_lock_retry"

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
    include AptLockRetry
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
      # `pkg:` is a documented alias of `name:` for real Ansible's
      # package:/dnf:/yum: modules (this module's own list of aliases
      # includes it) - buluma.bind's own `package: {pkg: "{{ item }}",
      # state: present}` always failed "Missing required parameter:
      # name" here, since only the literal `name:` key was ever read.
      name = @params["name"]? || @params["pkg"]?
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
      # `single_name` tracks whether `name:` is known to be exactly ONE
      # atomic package/group name - as opposed to this module's own
      # legacy space-joining of a genuinely multi-package templated list
      # (see below). This matters because a handful of real package/
      # group names legitimately CONTAIN a literal space (dnf's own
      # `@Server with GUI`/`@Development Tools` comps-group syntax is
      # the common case) - naively `name.split(' ')`-ing those apart (to
      # check each "name" individually, and passing them unquoted to
      # `dnf install -y`) silently mangled the group into 2-3 bogus
      # tokens ("@Server", "with", "GUI"), which dnf then rejected with
      # "Unable to find a match: with GUI" while real Ansible (which
      # never splits a single list item apart) installed the real group
      # fine. Found via robertdebock.gnome on Rocky 9.6 (`gnome_
      # packages: ["@Server with GUI"]`, RedHat's own default).
      single_name = false
      trimmed = name.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        # A Python-repr list (single-quoted strings) isn't valid JSON -
        # same fallback as apt.cr's own parse_package_names (see there
        # for the full rationale: a Jinja `{% if %}...{{ [list] }}...
        # {% endif %}` template idiom renders as Python's `str(list)`
        # form). Found live via prometheus.prometheus.blackbox_exporter's
        # own `ansible.builtin.package: name: "{{ _common_dependencies
        # }}"` task - _common_dependencies ultimately resolves through
        # exactly this template shape.
        parsed ||= begin
          Array(String).from_json(trimmed.gsub('\'', '"'))
        rescue
          nil
        end
        if parsed
          single_name = parsed.size == 1
          name = parsed.join(" ")
        end
      elsif trimmed.includes?(',')
        # A *literal* YAML list (`name: [tuned, python3-configobj]`,
        # unlike the templated-var JSON-bracket case above) is stringified
        # comma-joined by the parser - "the format every existing
        # plugin's list params already expect" per playbook_parser.cr's
        # own stringify_value, but apt-get/dpkg -l/rpm -q all need space-
        # separated names, not comma-separated (a real single package
        # name never contains a comma, so this can't misfire).
        parts = trimmed.split(',').map(&.strip).reject(&.empty?)
        single_name = parts.size == 1
        name = parts.join(" ")
      else
        single_name = !trimmed.includes?(' ')
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
        handle_dnf(name, state, single_name)
      when "apt"
        handle_apt(name, state, single_name)
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
    private def all_packages_installed?(name : String, single_name : Bool, & : String -> Bool) : Bool
      names = single_name ? [name] : name.split(' ').reject(&.empty?)
      names.all? { |pkg| yield pkg }
    end

    # Shell-safe form of `name` for the actual install/remove/query
    # command line: a single atomic name (may contain a literal space,
    # e.g. a dnf `@Group Name`) must be quoted as ONE token; a legacy
    # multi-name space-joined string is passed through unquoted exactly
    # as before (each word its own argument).
    private def shell_name(name : String, single_name : Bool) : String
      single_name ? shell_single_quote(name) : name
    end

    # A `@Group Name` spec (dnf's own comps-group syntax, e.g. RHEL's
    # `@Server with GUI`) is not an RPM package at all - `rpm -q` can
    # never match it (it queries individual RPM packages by name, with
    # no concept of a group), so the pre-install "already installed?"
    # check always returned false and every rerun re-ran `dnf install`
    # forever, even though dnf itself correctly no-ops (real Ansible's
    # dnf backend queries this through python-dnf's own group API,
    # which does understand groups, and IS idempotent). `dnf group list
    # installed` is the CLI-only equivalent: installed group names are
    # printed indented, no leading `@`, one per line, under either an
    # "Installed Environment Groups:" or "Installed Groups:" header -
    # verified live against dnf 4 on Rocky 9.6.
    private def dnf_group_installed?(spec : String) : Bool
      group_name = spec.lstrip('@')
      result = remote_exec("dnf group list installed 2>/dev/null")
      result[:stdout].split("\n").any? { |line| line.strip == group_name }
    end

    # Mirrors dnf.cr's own `is_url_or_file?` - a URL/local-path package
    # spec needs different installed-state handling than a bare name
    # (see handle_dnf's own comment for why `rpm -q` can't be trusted
    # for these).
    private def is_url_or_file?(name : String) : Bool
      name.starts_with?("http://") ||
        name.starts_with?("https://") ||
        name.starts_with?("ftp://") ||
        name.starts_with?("/")
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

      result = package_manager == "apt" ? apt_get_update_with_retry(command, AptLockRetry::DEFAULT_UPDATE_CACHE_RETRIES, AptLockRetry::DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY, ->remote_exec(String)) : remote_exec(command)
      return PluginResult.new(changed: false, failed: true, msg: "Failed to update package cache: #{result[:stderr]}") unless result[:exit_code] == 0

      # apt's own `update_cache: true` always reports changed: true
      # (verified in prior rounds - see apt.cr's own cache_update_is_
      # sole_operation handling for the OPPOSITE apt-specific gap, a
      # leaked changed: true when packages were ALSO being installed in
      # the same call). Real dnf.py's own `update_cache_only`, though,
      # reports `changed=result.get('changed', False)` from its internal
      # libdnf5-backed helper script - which, on the ansible-core/dnf5
      # combination verified live on a Rocky 9.6 target, never actually
      # sets a `changed` key at all, so it's always False in practice -
      # a real, dnf-specific difference from apt's own always-true
      # semantics, not something visible from `dnf makecache`'s own CLI
      # stdout (which prints the identical repo-download listing whether
      # or not anything was genuinely stale). Found via robertdebock.
      # update_package_cache's own single-task role.
      changed = package_manager == "apt"
      PluginResult.new(changed: changed, failed: false, msg: "Package cache updated")
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
    private def handle_dnf(name : String, state : String, single_name : Bool = false) : PluginResult
      # Check if package is installed - each name checked individually
      # (not `rpm -q #{name}` as one combined call) so a multi-package
      # `name:` (this module's own space-joined list, from a templated
      # list var) can't have one installed package mask another that
      # isn't: linux-system-roles/kernel_settings' `name: "tuned
      # python3-configobj"` previously read as "installed" the moment
      # *either* package matched.
      #
      # A URL/local-path `name:` (e.g. robertdebock.epel's own `epel_url:
      # https://dl.fedoraproject.org/.../epel-release-latest-9.noarch.
      # rpm`) must never be checked this way - `rpm -q <url-or-path>`
      # does NOT look up an installed-package NAME the way `rpm -q
      # <name>` does; real `rpm` treats a URL/path argument as a PACKAGE
      # FILE to query (fetching it first for a URL) and happily reports
      # the FILE's own embedded NEVRA with exit 0 as long as it's a
      # valid, fetchable RPM - regardless of whether that package is
      # actually installed on this system. That made a brand-new host
      # that had never installed epel-release before read as "already
      # installed" (exit 0 from a successful fetch-and-parse of the
      # remote RPM's metadata) and silently skip the real `dnf install`
      # entirely. Matches `dnf.cr`'s own `is_url_or_file?`-gated "always
      # try to install" handling for the identical case.
      is_installed = all_packages_installed?(name, single_name) do |pkg|
        if is_url_or_file?(pkg)
          false
        elsif pkg.starts_with?('@')
          dnf_group_installed?(pkg)
        else
          # Try a plain `rpm -q <name>` first - correctly matches both
          # a bare name and a NEVRA-style "name-version" specifier
          # (e.g. dj-wasabi.telegraf's own `telegraf-{{
          # telegraf_agent_version }}` pin). Only fall back to
          # `--whatprovides` (a Provides:/capability lookup) for a
          # VIRTUAL package name (a real RPM's `Provides:`, not a
          # package of its own - e.g. RHEL 9's `php-json`, bundled
          # into `php-common` since PHP 8.0), which a bare `rpm -q
          # <name>` never has an entry of its own to find even though
          # it's genuinely satisfied. `--whatprovides` ALONE regresses
          # the NEVRA case (`rpm -q --whatprovides telegraf-1.18.2`
          # fails even when that exact NEVRA is installed, verified
          # live) - both checks, in this order, are needed. Found
          # benchmarking buluma.mediawiki's own `package: name:
          # [php-intl, php-json, ...]` (the virtual-package case) and
          # dj-wasabi.telegraf's version-pinned case (round 158) - the
          # SAME bug class already independently present in dnf.cr's
          # and yum.cr's own copies of this exact check.
          remote_exec("rpm -q #{pkg}")[:exit_code] == 0 ||
            remote_exec("rpm -q --whatprovides #{pkg}")[:exit_code] == 0
        end
      end
      shell_pkg = shell_name(name, single_name)

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

          # --setopt=localpkg_gpgcheck=1 unless disable_gpg_check: - see
          # yum.cr's identical fix for the full story (real ansible's
          # dnf module forces `conf.localpkg_gpgcheck = not
          # disable_gpg_check`, overriding dnf's own actual gpgcheck-OFF
          # default for local/URL package installs). Applies here too:
          # `package:` with a URL/path `name:` shells straight to
          # dnf/yum with no gpgcheck override at all.
          gpg_opt = is_true?(@params["disable_gpg_check"]?) ? "--nogpgcheck" : "--setopt=localpkg_gpgcheck=1"
          install_result = remote_exec("dnf install -y #{gpg_opt} #{shell_pkg} || yum install -y #{gpg_opt} #{shell_pkg}")
          if install_result[:exit_code] == 0
            # A URL/path `name:` skipped the `rpm -q` pre-check above
            # (it can't tell "installed" from "valid RPM file"), so a
            # WARM rerun against an already-installed URL package always
            # reaches here - dnf itself still correctly no-ops and
            # prints "Nothing to do." with exit 0, so trusting the exit
            # code alone would report changed: true on every single
            # rerun, never converging. Same real-no-op-vs-exit-0 check
            # dnf.cr's own `handle_install` already does for the
            # identical reason.
            already_satisfied = is_url_or_file?(name) && install_result[:stdout].includes?("Nothing to do")
            return PluginResult.new(
              changed: !already_satisfied,
              failed: false,
              msg: already_satisfied ? "Package #{name} already installed" : "Package #{name} installed"
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
          
          remove_result = remote_exec("dnf remove -y #{shell_pkg} || yum remove -y #{shell_pkg}")
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
          check_update = remote_exec("dnf check-update #{shell_pkg} || yum check-update #{shell_pkg}")
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
        
        update_result = remote_exec("dnf install -y #{shell_pkg} || yum install -y #{shell_pkg}")
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
    private def handle_apt(name : String, state : String, single_name : Bool = false) : PluginResult
      # Check if package is installed - each name checked individually
      # (see handle_dnf's own comment for why: a single combined `dpkg -l
      # pkg1 pkg2 | grep '^ii'` matches as soon as *any* one of them is
      # installed, not all of them).
      is_installed = all_packages_installed?(name, single_name) { |pkg| remote_exec("dpkg -l #{pkg} 2>/dev/null | grep '^ii'")[:exit_code] == 0 }
      shell_pkg = shell_name(name, single_name)
      # Matches apt.cr's own lock_timeout retry (default 60s, same
      # param name as real Ansible's apt module) - this OS-agnostic
      # package: module has its own separate apt-get call sites that
      # weren't wrapped, so a dpkg-lock held by unattended-upgrades on a
      # freshly-booted Ubuntu host (a common real-world race, not
      # induced by this harness) failed fast here while real Ansible's
      # package:/apt: module waited it out. Found via buluma.aide's
      # `package: {name: aide}` task, round170.
      lock_timeout = @params["lock_timeout"]?.try(&.to_i) || 60

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
          
          install_result = apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y #{shell_pkg}", lock_timeout, ->remote_exec(String))
          if install_result[:exit_code] == 0
            # A requested name can be a virtual package already
            # satisfied by something else installed (`php-dom`/
            # `php-posix` aren't real dpkg packages on modern Ubuntu at
            # all, only names apt resolves via Provides: to
            # php8.1-xml/php8.1-common) - `is_installed`'s own `dpkg -l`
            # pre-check above only ever looks up the literal requested
            # name, which a purely virtual name never has a real dpkg
            # entry for, so it always fell through to "needs install"
            # here even on a warm rerun. apt-get's own exit code is 0
            # either way, so trusting exit_code alone always reported
            # changed: true - real Ansible's own apt module (and this
            # engine's separate apt.cr, which already had this exact
            # fix - see apt_summary_had_no_effect? there) correctly
            # treats apt's own "0 upgraded, 0 newly installed" summary
            # line as a no-op regardless of exit code. Found live
            # benchmarking robertdebock.nextcloud: `package: {name:
            # [php-bcmath, ..., php-dom, php-posix, ...]}` never
            # converged to changed: false on a warm rerun.
            summary = install_result[:stdout].match(/(\d+) upgraded, (\d+) newly installed/)
            had_no_effect = summary && summary[1] == "0" && summary[2] == "0"
            return PluginResult.new(
              changed: !had_no_effect,
              failed: false,
              msg: had_no_effect ? "Package #{name} already satisfied" : "Package #{name} installed"
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
          
          remove_result = apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive apt-get remove -y #{shell_pkg}", lock_timeout, ->remote_exec(String))
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
          check_upgrade = remote_exec("apt-get install --simulate #{shell_pkg} 2>&1 | grep -i upgrade")
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
        
        # `--only-upgrade` skips a package that isn't ALREADY installed
        # entirely (exit 0, "0 upgraded, 0 newly installed") - real
        # Ansible's own state: latest installs a not-yet-present package
        # too (plain apt-get install already does both), so this was
        # simply wrong - same bug independently duplicated in apt.cr's
        # own handle_latest (this module has its own separate apt
        # dispatch, not a shared one). Found via cloudalchemy.grafana's
        # own "Install Grafana" task (package: name: "{{ grafana_package
        # }}", state: "{{ ... | ternary('latest', 'present') }}") -
        # reported "changed: Package grafana upgraded to latest" while
        # the package was never actually installed at all.
        upgrade_result = apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y #{shell_pkg}", lock_timeout, ->remote_exec(String))

        # "N upgraded, M newly installed, ..." is apt's own reliable,
        # locale-stable summary line - checking for the English phrase
        # "already the newest version" (the previous approach) missed
        # the "not installed and only upgrades are requested" case
        # entirely.
        summary = upgrade_result[:stdout][/(\d+) upgraded, (\d+) newly installed/]?
        was_upgraded = summary ? summary.scan(/\d+/).map(&.[0].to_i).sum > 0 : upgrade_result[:exit_code] == 0

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

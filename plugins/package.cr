#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/apt_lock_retry"

module Krikri
  # Package Plugin - OS-agnostic package management
  #
  # Auto-detects package manager (dnf, yum, apt) and delegates
  #
  # Parameters:
  #   name (required): Package name
  #   state (optional): present, absent, latest (default: present)
  #   use (optional): Override the auto-detected package manager (apt,
  #     dnf, yum) - real Ansible's documented third option
  #   check_mode (optional): Dry-run mode
  #
  # Examples:
  #   package:
  #     name: nginx
  #     state: present
  class PackagePlugin < BasePlugin
    include AptLockRetry
    property? check_mode : Bool

    # The backend modules this engine actually ships - what a `use:`
    # name can resolve to. Real Ansible's package action plugin checks
    # its CONTROLLER-side module library (not target-side presence) and
    # fails anything not in it before the task runs: live-verified
    # (`ansible localhost -m package -a "use=nonexistentmgr ..."` =>
    # 'Could not find a matching action for the "nonexistentmgr"
    # package manager.'). This engine's module set is the honest
    # equivalent of that library, so a `use: zypper` on an engine
    # without a zypper module fails exactly the same way real Ansible
    # fails `use: homebrew`.
    PACKAGE_BACKEND_MODULES = ["apt", "dnf", "yum"]

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # A `use:` naming a module this engine doesn't ship fails before
      # anything else runs - real Ansible's action plugin validates its
      # backend selection ahead of module execution too, so even a
      # no-name invocation with a bogus `use:` fails rather than no-ops.
      if (use = requested_package_manager) && !PACKAGE_BACKEND_MODULES.includes?(use)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not find a matching action for the \"#{use}\" package manager."
        )
      end

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
      # Real Ansible's apt/dnf backends never hard-fail a missing/empty
      # `name:`. apt's own `required_one_of` gate is dead code in practice
      # (its `upgrade`/`autoremove` defaults are injected before the check
      # runs), and a no-name invocation falls through to a graceful
      # changed=false exit - verified live (`ansible localhost -m package
      # -a "state=present"` => SUCCESS, changed: false). adfinis-sygroup.
      # apache's own `package: {state: present}` loop task (round 83221)
      # relied on exactly that: no `name:` key at all, and real Ansible
      # ran it ok. A cache-refresh-only invocation still runs the
      # update_cache path below.
      name = @params["name"]? || @params["pkg"]?
      update_cache = true?(@params["update_cache"]?)
      unless name
        return update_cache ? update_cache_only : PluginResult.new(
          changed: false,
          failed: false,
          msg: "Nothing to do"
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
      # `names` is built directly per-branch (never re-derived by
      # re-splitting the space-joined `name` display string below) - a
      # group spec element containing a literal space (dnf's own
      # `@Development tools`) would otherwise get re-fragmented the
      # instant it sits alongside another list element: `parts`/`parsed`
      # already have the correct element boundaries the moment they're
      # computed, but `name.split(' ')` on their space-joined re-flatten
      # can't tell "gcc" + "@Development tools" (2 real elements) apart
      # from "gcc" + "@Development" + "tools" (3 space-separated words) -
      # found live testing `package: {name: [gcc, "@Development tools"]}`
      # against this exact fix: still produced the original "Unable to
      # find a match: tools" bug the fix otherwise closes.
      names = [trimmed]
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
          names = parsed
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
        names = parts
        name = parts.join(" ")
      else
        # A dnf comps-group spec (`@Development tools`) legitimately
        # contains a literal space and is still ONE atomic name - real
        # Ansible's package/dnf module treats a string `name:` as a
        # single element and passes it whole to dnf's group API. Found
        # via andrewrothstein.gcc-toolbox's `package: {name: '{{ item }}'}`
        # loop on Rocky 9.6 (round 65000+): the space made this look
        # like the legacy multi-name string, the group reached dnf
        # unquoted as two tokens (`@Development` + `tools`), and dnf
        # rejected it with "Unable to find a match: tools" while real
        # ansible-playbook installed the group fine.
        single_name = trimmed.starts_with?('@') || !trimmed.includes?(' ')
        names = single_name ? [trimmed] : trimmed.split(' ').reject(&.empty?)
      end

      # A name that templates down to nothing - an empty string or an
      # empty list (`name: '{{ ntp_packages_removed }}'` with the var
      # defaulting to `[]`, round 83246) - is a no-op, not a package
      # operation on the empty-string name. Real Ansible's apt backend
      # exits changed=false for an empty package list (`install([])`
      # returns immediately) for both state: present and state: absent;
      # this engine instead used to run `apt-get remove` on the empty
      # token and report "Package  removed" (double space) as changed on
      # every run, breaking idempotency.
      return PluginResult.new(changed: false, failed: false, msg: "Nothing to do") if
        names.empty? || names.all?(&.strip.empty?)

      # Per-element shell quoting for the actual package-manager command
      # line - each element quoted as its own atomic token, since a
      # legit element can itself contain a space (dnf's
      # `@Development tools` group syntax).
      pkg_tokens = names.map { |pkg| shell_single_quote(pkg) }.join(" ")

      state = @params["state"]? || "present"
      # Real Ansible's package/dnf/yum modules accept "installed"/"removed"
      # as synonyms for "present"/"absent" (documented state choices:
      # absent, installed, latest, present, removed) - found via
      # bertvv.rh-base's own `package: state: installed` failing here with
      # "Invalid state" instead of installing.
      state = "present" if state == "installed"
      state = "absent" if state == "removed"

      # Resolve the backend: an explicit `use:` overrides auto-detection
      # UNCONDITIONALLY - it dispatches straight to the named module and
      # is not a fallback. Live-verified against real ansible-core
      # 2.19.4: `use: dnf` on this apt host still dispatched to the dnf
      # module (which then failed on-target with "Could not import the
      # dnf python module..."), rather than silently reverting to apt.
      package_manager = requested_package_manager || detect_package_manager()

      unless package_manager
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not detect a package manager on this host"
        )
      end

      # Delegate to appropriate package manager
      case package_manager
      when "dnf", "yum"
        handle_dnf(name, state, names, pkg_tokens)
      when "apt"
        handle_apt(name, state, names, pkg_tokens)
      else
        # Detected, but this engine ships no backend for it - say which
        # one, rather than claiming none was found. zypper/pacman/apk are
        # documented scope cuts (see KNOWN_MISSING.md), not oversights.
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "package manager '#{package_manager}' is not supported by this engine"
        )
      end
    end

    # `name:` may be several space-separated package names (this module's
    # own space-joining of a templated list var - see the JSON-array
    # handling in #execute above). True only if *every* one is installed,
    # not merely one of them.
    # One `dpkg-query` round trip for the whole package list (see
    # apt.cr's dpkg_installed_status for the full rationale - duplicated
    # here because apt.cr and package.cr are separate plugin binaries).
    private def dpkg_installed_status(packages : Array(String)) : Hash(String, {Bool, String?})
      statuses = Hash(String, {Bool, String?}).new
      return statuses if packages.empty?

      bare_names = packages.map(&.split('=').first)
      name_list = bare_names.map { |pkg| shell_single_quote(pkg) }.join(" ")
      result = remote_exec("dpkg-query -W -f='${db:Status-Abbrev} ${Version} ${Package}
' #{name_list} 2>/dev/null")
      result[:stdout].each_line do |line|
        parts = line.split(/\s+/, 3)
        next unless parts.size == 3
        bare = parts[2].strip.split(":").first
        next if statuses.has_key?(bare)
        installed = parts[0].starts_with?("ii")
        statuses[bare] = {installed, installed ? parts[1] : nil}
      end
      statuses
    end

    # True only if *every* parsed name element is installed, not merely
    # one of them.
    private def all_packages_installed?(names : Array(String), & : String -> Bool) : Bool
      names.all? { |pkg| yield pkg }
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
      # Case-insensitive: dnf's own group matching is, and the common
      # real-world spec `@Development tools` doesn't share the comps
      # metadata's own capitalization (`Development Tools`) - a
      # case-sensitive compare made every warm rerun see the group as
      # not installed and re-run a full `dnf install` forever.
      result[:stdout].split("\n").any? { |line| line.strip.downcase == group_name.downcase }
    end

    # Mirrors dnf.cr's own `url_or_file?` - a URL/local-path package
    # spec needs different installed-state handling than a bare name
    # (see handle_dnf's own comment for why `rpm -q` can't be trusted
    # for these).
    private def url_or_file?(name : String) : Bool
      name.starts_with?("http://") ||
        name.starts_with?("https://") ||
        name.starts_with?("ftp://") ||
        name.starts_with?("/")
    end

    # update_cache: true with no name: - just refresh the package
    # manager's own index, matching real Ansible's own cache-refresh-
    # only idiom for package:/apt:.
    private def update_cache_only : PluginResult
      package_manager = requested_package_manager || detect_package_manager()
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

      # Real Ansible's `package:` delegates to the apt module on apt
      # hosts, whose module-start auto-install (see AptLockRetry#
      # apt_auto_install_python_apt) puts python3-apt in place on the
      # FIRST package: invocation - so its own cache-refresh-only
      # changed-reporting is decided by the mtime-diff path on every
      # subsequent one. Mirror that here or a host that starts without
      # the bindings stays on apt_cache_refresh_changed?'s
      # absent → changed=false path forever (the geerlingguy.kubernetes
      # divergence class, rounds 65166/65311). `update_cache: true` is
      # not explicitly false here, so the auto-install runs its
      # `apt-get update` prefetch too - which real Ansible's respawned
      # module ALSO runs its own mtime-windowed update after, so an
      # all-Hit second pass still reports changed=false (round 30001
      # semantics preserved).
      #
      # Check mode must never perform that auto-install - it is a real,
      # persistent mutation of the target. Real Ansible's apt module
      # refuses to run at all in that situation instead, and `package:`
      # delegates to it, so mirror the same refusal apt.cr's own
      # update-cache block already carries.
      if package_manager == "apt"
        if refusal = apt_check_mode_python_apt_refusal(@check_mode, ->remote_exec(String))
          return PluginResult.new(changed: false, failed: true, msg: refusal)
        end
        unless @check_mode
          if failure = apt_auto_install_python_apt(false, ->remote_exec(String))
            return PluginResult.new(changed: false, failed: true, msg: "Failed to auto-install python3-apt: #{failure[:stderr]}")
          end
        end
      end

      pre_update_mtime = package_manager == "apt" ? apt_cache_mtime(->remote_exec(String)) : 0
      result = package_manager == "apt" ? apt_get_update_with_retry(command, AptLockRetry::DEFAULT_UPDATE_CACHE_RETRIES, AptLockRetry::DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY, ->remote_exec(String)) : remote_exec(command)
      return PluginResult.new(changed: false, failed: true, msg: "Failed to update package cache: #{result[:stderr]}") unless result[:exit_code] == 0

      # Real dnf.py's own `update_cache_only` reports
      # `changed=result.get('changed', False)` from its internal
      # libdnf5-backed helper script - which, on the ansible-core/dnf5
      # combination verified live on a Rocky 9.6 target, never actually
      # sets a `changed` key at all, so it's always False in practice -
      # a real, dnf-specific difference from apt's own semantics, not
      # something visible from `dnf makecache`'s own CLI stdout (which
      # prints the identical repo-download listing whether or not
      # anything was genuinely stale). Found via robertdebock.
      # update_package_cache's own single-task role.
      #
      # apt's own `changed` here is NOT always true - it depends on
      # python3-apt's presence and whether the cache mtime actually
      # moved, exactly like apt.cr's own cache-refresh-only path (see
      # AptLockRetry#apt_cache_refresh_changed? for the full real-Ansible
      # semantics this mirrors, round 30001). This module previously
      # hardcoded `changed: true` for apt unconditionally - an
      # independent duplicate of apt.cr's own logic that drifted from
      # the fix apt.cr already got, reproducing the exact false-changed
      # regression round 30001 closed there. Found again via
      # robertdebock.update_package_cache on a mirror that was already
      # current: real Ansible reported `ok`, this module `changed`.
      changed = package_manager == "apt" && apt_cache_refresh_changed?(pre_update_mtime, apt_cache_mtime(->remote_exec(String)), ->remote_exec(String))
      PluginResult.new(changed: changed, failed: false, msg: "Package cache updated")
    end

    # Detect which package manager is available
    # Real Ansible's `package:` is a wrapper: its action plugin reads the
    # `ansible_pkg_mgr` fact and dispatches to that manager's own module.
    # This used to run its own separate `which dnf`/`which yum`/`which
    # apt-get` probe, which diverged from the fact this engine ALREADY
    # gathers (`FactsGatherer#detect_pkg_mgr`) in two ways, both of which
    # produce a wrong or misleading answer rather than a clean one:
    #
    #   - `which` consults $PATH only, while real Ansible's PKG_MGRS
    #     table matches on absolute paths - so a manager installed
    #     outside a non-login SSH shell's PATH went undetected.
    #   - A host whose package manager is real but unimplemented here
    #     (apk, pacman, zypper, ...) reported "Could not detect package
    #     manager (tried: dnf, yum, apt)" - actively false on an Alpine
    #     or Arch host, which plainly HAS one. Naming the manager that
    #     was found is the difference between "this engine doesn't
    #     support your platform" and "your platform looks broken".
    #
    # Same path list and same dnf-before-yum priority as the facts
    # gatherer, so the module and the `ansible_pkg_mgr` a role gates on
    # can never disagree.
    PKG_MGR_PATHS = {
      "/usr/bin/dnf"     => "dnf",
      "/usr/bin/yum"     => "yum",
      "/usr/bin/apt-get" => "apt",
      "/usr/bin/zypper"  => "zypper",
      "/usr/bin/pacman"  => "pacman",
      "/sbin/apk"        => "apk",
      "/usr/sbin/pkg"    => "pkgng",
    }

    # Backend resolution order, mirroring real Ansible's package action
    # plugin: an explicit `use:` task option wins; otherwise the
    # `ansible_package_use` variable (real Ansible 2.17+) overrides
    # auto-detection; otherwise detection runs (real Ansible reads the
    # `ansible_pkg_mgr` fact). An explicit `use: auto` (the documented
    # default) participates in the same fall-through - the action plugin
    # only consults the variable and facts when the option is "auto".
    private def requested_package_manager : String?
      use = @params["use"]?
      use = nil if use == "auto"
      use || @vars["ansible_package_use"]?.try(&.as_s?)
    end

    private def detect_package_manager : String?
      probe = PKG_MGR_PATHS.keys.map { |path| "[ -x #{path} ] && echo #{path}" }.join("; ")
      found = remote_exec(probe)[:stdout].to_s.lines.map(&.strip).reject(&.empty?)
      PKG_MGR_PATHS.each do |path, name|
        return name if found.includes?(path)
      end
      nil
    end

    # Handle DNF/YUM package management
    # See #execute's `names`/`pkg_tokens` comment: commands are built
    # from the parsed elements (each atomically quoted), messages keep
    # the joined display form.
    private def handle_dnf(name : String, state : String, names : Array(String), pkg_tokens : String) : PluginResult
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
      # entirely. Matches `dnf.cr`'s own `url_or_file?`-gated "always
      # try to install" handling for the identical case.
      is_installed = all_packages_installed?(names) do |pkg|
        if url_or_file?(pkg)
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
      shell_pkg = pkg_tokens

      case state
      when "present"
        if is_installed
          PluginResult.new(
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
          gpg_opt = true?(@params["disable_gpg_check"]?) ? "--nogpgcheck" : "--setopt=localpkg_gpgcheck=1"
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
            already_satisfied = url_or_file?(name) && install_result[:stdout].includes?("Nothing to do")
            PluginResult.new(
              changed: !already_satisfied,
              failed: false,
              msg: already_satisfied ? "Package #{name} already installed" : "Package #{name} installed"
            )
          else
            PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to install #{name}: #{install_result[:stderr]}",
              stderr: install_result[:stderr]
            )
          end
        end
      when "absent"
        if !is_installed
          PluginResult.new(
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
            PluginResult.new(
              changed: true,
              failed: false,
              msg: "Package #{name} removed"
            )
          else
            PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to remove #{name}: #{remove_result[:stderr]}"
            )
          end
        end
      when "latest"
        if @check_mode
          # check-update returns 100 if updates are available. The old
          # `dnf check-update X || yum check-update X` swallowed dnf's
          # exit-100 (non-zero runs the yum fallback, whose own exit code
          # then replaced it), so a pending update looked like
          # "already at latest". Capture dnf's rc explicitly and only
          # fall through to yum when dnf itself failed (e.g. not
          # installed); yum's own 100 then propagates as the exit code.
          check_update = remote_exec(
            "dnf check-update #{shell_pkg}; rc=$?; " \
            "if [ $rc -eq 100 ]; then exit 100; fi; " \
            "if [ $rc -ne 0 ]; then yum check-update #{shell_pkg} || exit $?; fi"
          )
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

        PluginResult.new(
          changed: was_updated,
          failed: false,
          msg: was_updated ? "Package #{name} updated to latest" : "Package #{name} already at latest version"
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
    end

    # Handle APT package management
    private def handle_apt(name : String, state : String, names : Array(String), pkg_tokens : String) : PluginResult
      # Real Ansible's `package:` action plugin delegates to the apt
      # module on Debian-family hosts, and apt.py's main() runs the cache
      # refresh BEFORE install() whenever update_cache: is set (or any
      # cache_valid_time: is) - unconditionally with the default
      # cache_valid_time: 0 (only the stamp-mtime + cache_valid_time <
      # now staleness gate can skip it), and even when every requested
      # package is already installed. This module only honored
      # update_cache: on the name-less cache-refresh-only path above, so
      # `ansible.builtin.package: {name: [...], update_cache: true}`
      # installed straight off whatever package index the host image was
      # built with: a stale index resolves names to long-superseded
      # versions, and apt 404s fetching their .debs from the live mirror
      # (which only carries current versions). Found via rounds
      # 72311/72313/72363 (lfit.lf-dev-libs, lfit.mono-install,
      # markosamuli.pyenv) - all three hit 404s on 2022-era versions on
      # freshly-provisioned hosts while real Ansible, which refreshed the
      # cache first, resolved current versions and succeeded on the same
      # task. Check mode skips the refresh: real Ansible's `if not
      # module.check_mode: cache.update()` guard skips it too.
      update_cache = true?(@params["update_cache"]?)
      cache_valid_time = @params["cache_valid_time"]?.try(&.to_i) || 0
      if failure = apt_update_cache_before_operation(
             update_cache, cache_valid_time,
             @params["update_cache_retries"]?.try(&.to_i) || AptLockRetry::DEFAULT_UPDATE_CACHE_RETRIES,
             @params["update_cache_retry_max_delay"]?.try(&.to_i) || AptLockRetry::DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY,
             @check_mode, ->remote_exec(String))
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to update apt cache: #{failure[:stderr]}"
        )
      end

      # Check if package is installed - each name checked individually
      # (see handle_dnf's own comment for why: a single combined `dpkg -l
      # pkg1 pkg2 | grep '^ii'` matches as soon as *any* one of them is
      # installed, not all of them).
      # One batched dpkg-query for the whole list instead of one
      # `dpkg -l <pkg>` per package (mirrors apt.cr's own
      # dpkg_installed_status; the two are separate plugin binaries, so
      # the helper is duplicated rather than shared).
      apt_names = names
      installed_status = dpkg_installed_status(apt_names)
      is_installed = apt_names.all? do |pkg|
        base_name = pkg.split('=').first
        installed_status[base_name]?.try { |pair| pair[0] } || false
      end
      shell_pkg = pkg_tokens
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
          PluginResult.new(
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

          install_result = apt_install_with_implicit_cache_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y #{shell_pkg}", lock_timeout, ->remote_exec(String))
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
            PluginResult.new(
              changed: !had_no_effect,
              failed: false,
              msg: had_no_effect ? "Package #{name} already satisfied" : "Package #{name} installed"
            )
          else
            PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to install #{name}: #{install_result[:stderr]}",
              stderr: install_result[:stderr]
            )
          end
        end
      when "absent"
        if !is_installed
          PluginResult.new(
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
            PluginResult.new(
              changed: true,
              failed: false,
              msg: "Package #{name} removed"
            )
          else
            PluginResult.new(
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
        # Wrapped with the same implicit cache-update retry on corrupt/
        # unparseable lists that apt.cr's own install/latest paths get
        # (real Ansible silently recovers a corrupt on-disk index this
        # way - see apt_install_with_implicit_cache_retry; a plain
        # locate-miss on an otherwise-valid cache, e.g. `package:
        # {name: w3m, state: present}` against a merely-empty
        # /var/lib/apt/lists/, is NOT retried by real ansible-playbook
        # either - it fails outright with "No package matching 'w3m' is
        # available").
        upgrade_result = apt_install_with_implicit_cache_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y #{shell_pkg}", lock_timeout, ->remote_exec(String))

        # apt-get prints its "N upgraded, M newly installed" summary line
        # during dependency RESOLUTION, before any package is actually
        # fetched or installed - so a later fetch failure (a stale mirror
        # 404ing on one of the resolved dependencies, e.g.) still leaves
        # that summary line sitting in stdout with a nonzero count, and
        # exit_code alone was never checked below. Real apt-get exits
        # non-zero in that case ("E: Unable to fetch some archives") and
        # nothing was actually installed - this OS-agnostic module's own
        # separate apt dispatch reported `changed: true` regardless, the
        # exact "changed but never installed" bug apt.cr's own
        # handle_latest already guards against (see there) but this
        # independently-implemented duplicate never got. Found live via
        # evrardjp.keepalived's own "Install keepalived package(s)" task
        # on a fresh Atlantic Ubuntu 22.04 host: a 404 on libsnmp-base (a
        # resolved dependency) failed the real apt-get install outright,
        # but this code still reported "Package keepalived upgraded to
        # latest" - `dpkg -l keepalived` on the host confirmed it was
        # never installed at all.
        if upgrade_result[:exit_code] != 0
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to install #{name}: #{upgrade_result[:stderr]}",
            stderr: upgrade_result[:stderr]
          )
        end

        # "N upgraded, M newly installed, ..." is apt's own reliable,
        # locale-stable summary line - checking for the English phrase
        # "already the newest version" (the previous approach) missed
        # the "not installed and only upgrades are requested" case
        # entirely.
        summary = upgrade_result[:stdout][/(\d+) upgraded, (\d+) newly installed/]?
        was_upgraded = summary ? summary.scan(/\d+/).sum(&.[0].to_i) > 0 : upgrade_result[:exit_code] == 0

        PluginResult.new(
          changed: was_upgraded,
          failed: false,
          msg: was_upgraded ? "Package #{name} upgraded to latest" : "Package #{name} already at latest version"
        )
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
    end

    # Helper to convert string/bool to boolean
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PackagePlugin.new(config)
plugin.run

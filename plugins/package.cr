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
  #     dnf, yum) - Ansible's documented third option
  #   check_mode (optional): Dry-run mode
  #
  # Examples:
  #   package:
  #     name: nginx
  #     state: present
  class PackagePlugin < BasePlugin
    # Ansible's package: action plugin forwards the call to the detected
    # backend module, whose own argspec validates every provided param -
    # so the engine's package plugin validates the UNION of its backends'
    # `type: bool` options (apt + dnf; ansible-doc -j). Validated by
    # BasePlugin#validate_bool_params! - see its block comment. A bool
    # param only the OTHER family's backend has fails here with the bool
    # wording where Ansible would fail it as an unsupported param - same
    # outcome, different message, accepted edge.
    protected def bool_params : Array(String)
      %w[allow_change_held_packages allow_downgrade allow_unauthenticated
        auto_install_module_deps autoclean autoremove best bugfix cacheonly clean
        disable_gpg_check download_only fail_on_autoremove force force_apt_get
        install_repoquery install_weak_deps nobest only_upgrade purge security skip_broken
        sslverify update_cache update_only validate_certs]
    end

    protected def bool_param_aliases : Hash(String, String)
      {
        "allow-downgrade"       => "allow_downgrade",
        "allow_downgrades"      => "allow_downgrade",
        "allow-downgrades"      => "allow_downgrade",
        "allow-unauthenticated" => "allow_unauthenticated",
        "install-recommends"    => "install_recommends",
        "update-cache"          => "update_cache",
        "expire-cache"          => "update_cache",
      }
    end

    # These default to None in Ansible's argspec, so an explicit null skips
    # type validation there (see StrictBoolValidation#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[best install_recommends nobest update_cache]
    end

    include AptLockRetry
    property? check_mode : Bool
    # Resolved remote path of apt-get (see #apt_get_bin), nil until first
    # needed.
    @apt_get_bin : String? = nil

    # The backend modules this engine actually ships - what a `use:`
    # name can resolve to. Ansible's package action plugin checks
    # its CONTROLLER-side module library (not target-side presence) and
    # fails anything not in it before the task runs: live-verified
    # (`ansible localhost -m package -a "use=nonexistentmgr ..."` =>
    # 'Could not find a matching action for the "nonexistentmgr"
    # package manager.'). This engine's module set is the honest
    # equivalent of that library, so a `use: zypper` on an engine
    # without a zypper module fails exactly the same way Ansible
    # fails `use: homebrew`.
    PACKAGE_BACKEND_MODULES = ["apt", "dnf", "yum"]

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute : PluginResult
      # A `use:` naming a module this engine doesn't ship fails before
      # anything else runs - Ansible's action plugin validates its
      # backend selection ahead of module execution too, so even a
      # no-name invocation with a bogus `use:` fails rather than no-ops.
      if (use = requested_package_manager) && !PACKAGE_BACKEND_MODULES.includes?(use)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not find a matching action for the \"#{use}\" package manager."
        )
      end

      # Backend-argspec bool validation (see the bool_params comment above).
      validate_bool_params!

      # Validate required parameters. `name:` isn't required when
      # update_cache: true is given with nothing else - Ansible's
      # own package:/apt: modules allow a cache-refresh-only invocation,
      # a real idiom (ansible-community.ansible-vault's own "Update
      # package cache" task does exactly this: `package: {update_cache:
      # true}`, no name: at all). Matches apt.cr's own identical
      # exception for the same case.
      # `pkg:` is a documented alias of `name:` for Ansible's
      # package:/dnf:/yum: modules (this module's own list of aliases
      # includes it) - buluma.bind's own `package: {pkg: "{{ item }}",
      # state: present}` always failed "Missing required parameter:
      # name" here, since only the literal `name:` key was ever read.
      # Ansible's apt/dnf backends never hard-fail a missing/empty
      # `name:`. apt's own `required_one_of` gate is dead code in practice
      # (its `upgrade`/`autoremove` defaults are injected before the check
      # runs), and a no-name invocation falls through to a graceful
      # changed=false exit - verified live (`ansible localhost -m package
      # -a "state=present"` => SUCCESS, changed: false). adfinis-sygroup.
      # apache's own `package: {state: present}` loop task (round 83221)
      # relied on exactly that: no `name:` key at all, and Ansible
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
      # "Unable to find a match: with GUI" while Ansible (which
      # never splits a single list item apart) installed the real group
      # fine. Found via robertdebock.gnome on Rocky 9.6 (`gnome_
      # packages: ["@Server with GUI"]`, RedHat's own default).
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
        # ONLY valid JSON - never a Python-repr repair pass. A value that
        # merely LOOKS like a container (a literal `name: "['pkg1']"`
        # string, or a `{% if %}...{% else %}['pkg1']{% endif %}` block's
        # rendered output) is a plain STRING in ansible-core -
        # native typing requires the template's whole AST to be one
        # output node wrapping one expression, so block-tag output is
        # never re-parsed. A whole-value `{{ list_var }}` container arg
        # arrives as the double-quoted JSON the wire serialized it to
        # (see substitute_task_params's whole-single-span comment), which
        # the plain JSON parse above already handles. Live-verified vs
        # ansible-playbook 2.19.11: `package: name: "['probe-pkg-one',
        # 'probe-pkg-two']"` fails with "No package(s) matching
        # '['probe-pkg-one'' available" (Ansible comma-splits the
        # repr-looking string into garbage names and fails looking them
        # up) - the old single-quote repair here decomposed it into a
        # real list and installed both packages instead.
        if parsed
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
        # name never contains a comma, so this can't misfire). Empty
        # comma segments are KEPT: Ansible fails the install with
        # "No package matching '' is available" for one (live-verified
        # for the apt backend, see apt.cr's parse_package_names).
        parts = trimmed.split(',').map(&.strip)
        names = parts
        name = parts.join(" ")
      else
        # A dnf comps-group spec (`@Development tools`) legitimately
        # contains a literal space and is still ONE atomic name -
        # Ansible's package/dnf module treats a string `name:` as a
        # single element and passes it whole to dnf's group API. Found
        # via andrewrothstein.gcc-toolbox's `package: {name: '{{ item }}'}`
        # loop on Rocky 9.6 (round 65000+): the space made this look
        # like the legacy multi-name string, the group reached dnf
        # unquoted as two tokens (`@Development` + `tools`), and dnf
        # rejected it with "Unable to find a match: tools" while
        # ansible-playbook installed the group fine.
        single_name = trimmed.starts_with?('@') || !trimmed.includes?(' ')
        names = single_name ? [trimmed] : trimmed.split(' ').reject(&.empty?)
      end

      # An empty LIST (`name: '{{ ntp_packages_removed }}'` with the var
      # defaulting to `[]`, round 83246 - arriving as the literal text
      # "[]" and JSON-decoded above, or a literal `name: []` stringified
      # to "[]" by parse_module_params) is a no-op, not a package
      # operation: Ansible's apt backend exits changed=false for an
      # empty package list (`install([])` returns immediately) for both
      # state: present and state: absent; this engine instead used to
      # run `apt-get remove` on the empty token and report "Package
      # removed" (double space) as changed on every run, breaking
      # idempotency.
      return PluginResult.new(changed: false, failed: false, msg: "Nothing to do") if names.empty?

      # Per-element shell quoting for the actual package-manager command
      # line - each element quoted as its own atomic token, since a
      # legit element can itself contain a space (dnf's
      # `@Development tools` group syntax).
      pkg_tokens = names.map { |pkg| shell_single_quote(pkg) }.join(" ")

      state = @params["state"]? || "present"

      # Resolve the backend BEFORE validating state: Ansible's
      # `package:` is a dispatcher whose argument validation happens
      # inside the DELEGATED module, so the accepted state choices are
      # host-dependent. Live-verified against ansible-core 2.19.11
      # (ChristopherDavenport.universal-tomcat, round 984025): on a
      # Debian-family host `state: installed` fails at setup with apt's
      # choices list ("value of state must be one of: absent, build-dep,
      # fixed, latest, present, got: installed"), while on RedHat-family
      # hosts dnf/yum legitimately accept installed/removed (the
      # bertvv.rh-base case the old blanket synonym mapped). The
      # previous unconditional installed→present / removed→absent alias
      # accepted on apt hosts exactly where Ansible errors.
      package_manager = requested_package_manager || detect_package_manager()

      unless package_manager
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not detect a package manager on this host"
        )
      end

      if package_manager == "apt"
        apt_states = %w[absent build-dep fixed latest present]
        unless apt_states.includes?(state)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "value of state must be one of: #{apt_states.join(", ")}, got: #{state}"
          )
        end
      else
        state = "present" if state == "installed"
        state = "absent" if state == "removed"
      end

      # An empty name that SURVIVED parsing (`name: ""`, or an empty
      # comma segment) is a hard failure for present/latest -
      # Ansible treats it as one (invalid) package name and fails with
      # "No package matching '' is available" (live-verified vs
      # ansible-playbook 2.19.11 for both the apt and package modules in
      # check mode). state: absent tolerates one - Ansible's remove
      # path just reports ok there. The old `names.all?(&.strip.empty?)`
      # "Nothing to do" collapsed this into a silent success where
      # Ansible fails the task.
      if state != "absent" && names.any?(&.empty?)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "No package matching '' is available"
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

    # Ansible's apt module runs EVERY package operation with its own
    # default dpkg options (apt.py's DPKG_OPTIONS = "force-confdef,
    # force-confold", overridable via the dpkg_options: param the package
    # action plugin forwards verbatim). This module's own separate apt
    # dispatch (not a shared one with apt.cr - see handle_latest's comment
    # above) never threaded them in, so an install whose package ships a
    # conffile that already exists on disk unowned made dpkg stop and
    # prompt on stdin for the conflict - and with this engine's /dev/null
    # stdin that prompt dies with "end of file on stdin at conffile
    # prompt", failing the whole install. Ansible's flags resolve the
    # exact same conflict silently to "keep current" and the task
    # succeeds. Found via weareinteractive.docker (round 979177): the role
    # templates /etc/default/docker BEFORE `package: docker-ce` ever runs,
    # so docker-ce's unpack hit the unowned-conffile prompt and the
    # "Installing packages" task failed here while ansible-playbook
    # installed the same packages fine on an identical fresh host.
    private def expand_dpkg_options : String
      (@params["dpkg_options"]? || "force-confdef,force-confold").split(",")
        .map(&.strip).reject(&.empty?)
        # Real apt passes each option as its own argv element
        # (-o Dpkg::Options::=--<opt>), where a hostile opt is inert;
        # quote_arg keeps the well-formed comma list byte-identical.
        .map { |opt| "-o Dpkg::Options::=--#{Shell.quote_arg(opt)}" }.join(" ")
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
    # forever, even though dnf itself correctly no-ops (Ansible's
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
    # manager's own index, matching Ansible's own cache-refresh-
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

      # Ansible's `package:` delegates to the apt module on apt
      # hosts, whose module-start auto-install (see AptLockRetry#
      # apt_auto_install_python_apt) puts python3-apt in place on the
      # FIRST package: invocation - so its own cache-refresh-only
      # changed-reporting is decided by the mtime-diff path on every
      # subsequent one. Mirror that here or a host that starts without
      # the bindings stays on apt_cache_refresh_changed?'s
      # absent → changed=false path forever (the geerlingguy.kubernetes
      # divergence class, rounds 65166/65311). `update_cache: true` is
      # not explicitly false here, so the auto-install runs its
      # `apt-get update` prefetch too - which Ansible's respawned
      # module ALSO runs its own mtime-windowed update after, so an
      # all-Hit second pass still reports changed=false (round 30001
      # semantics preserved).
      #
      # Check mode must never perform that auto-install - it is a real,
      # persistent mutation of the target. Ansible's apt module
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

      # Ansible's apt module (which `package:` delegates to on apt
      # hosts) gates this same refresh on `cache_valid_time:` staleness
      # (apt.py's Cache.update(cache_valid_time=...)): a positive window
      # that the update-success-stamp/lists-dir mtime is still inside
      # skips `apt-get update` entirely and exits changed=false. This
      # path never read `cache_valid_time:` at all and always ran the
      # refresh, so a warm rerun inside the window still touched the apt
      # lists and reported changed: true where Ansible reported ok
      # (buluma.security, round 952553). Same shared helper apt.cr's own
      # update-cache path uses, so the two can't drift again.
      if package_manager == "apt"
        cache_valid_time = @params["cache_valid_time"]?.try(&.to_i) || 0
        unless apt_cache_stale?(cache_valid_time, ->remote_exec(String))
          return PluginResult.new(changed: false, failed: false, msg: "Cache up to date")
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
      # current: Ansible reported `ok`, this module `changed`.
      changed = package_manager == "apt" && apt_cache_refresh_changed?(pre_update_mtime, apt_cache_mtime(->remote_exec(String)), ->remote_exec(String))
      PluginResult.new(changed: changed, failed: false, msg: "Package cache updated")
    end

    # Detect which package manager is available
    # Ansible's `package:` is a wrapper: its action plugin reads the
    # `ansible_pkg_mgr` fact and dispatches to that manager's own module.
    # This used to run its own separate `which dnf`/`which yum`/`which
    # apt-get` probe, which diverged from the fact this engine ALREADY
    # gathers (`FactsGatherer#detect_pkg_mgr`) in two ways, both of which
    # produce a wrong or misleading answer rather than a clean one:
    #
    #   - `which` consults $PATH only, while Ansible's PKG_MGRS
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

    # Backend resolution order, mirroring Ansible's package action
    # plugin: an explicit `use:` task option wins; otherwise the
    # `ansible_package_use` variable (Ansible 2.17+) overrides
    # auto-detection; otherwise detection runs (Ansible reads the
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
          remote_exec("rpm -q #{shell_single_quote(pkg)}")[:exit_code] == 0 ||
            remote_exec("rpm -q --whatprovides #{shell_single_quote(pkg)}")[:exit_code] == 0
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
          # yum.cr's identical fix for the full story (Ansible's
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
    # Real apt's check-mode simulate exit shape (live-verified 2.19.11 via
    # package: check mode on this apt host): the simulate run's raw
    # stdout/stderr under changed: true, an empty diff object, and the
    # cache pair - with stdout_lines/stderr_lines emitted here so they
    # land between cache_update_time and the executor's failed backfill,
    # exactly where Ansible's registered result shows them.
    private def simulate_result(stdout : String, stderr : String) : PluginResult
      PluginResult.new(
        changed: true,
        failed: false,
        stdout: stdout,
        stderr: stderr,
        diff: JSON.parse("{}"),
        cache_updated: false,
        cache_update_time: apt_cache_mtime(->remote_exec(String)),
        stdout_lines: PluginHelpers::AnsibleSplitlines.split(stdout),
        stderr_lines: PluginHelpers::AnsibleSplitlines.split(stderr),
        key_order: %w[changed stdout stderr diff cache_updated cache_update_time stdout_lines stderr_lines]
      )
    end

    private def handle_apt(name : String, state : String, names : Array(String), pkg_tokens : String) : PluginResult
      # Ansible's `package:` action plugin delegates to the apt
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
      # freshly-provisioned hosts while Ansible, which refreshed the
      # cache first, resolved current versions and succeeded on the same
      # task. Check mode skips the refresh: Ansible's `if not
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
      # param name as Ansible's apt module) - this OS-agnostic
      # package: module has its own separate apt-get call sites that
      # weren't wrapped, so a dpkg-lock held by unattended-upgrades on a
      # freshly-booted Ubuntu host (a common real-world race, not
      # induced by this harness) failed fast here while Ansible's
      # package:/apt: module waited it out. Found via buluma.aide's
      # `package: {name: aide}` task, round170.
      lock_timeout = @params["lock_timeout"]?.try(&.to_i) || 60
      # Ansible's own default dpkg options, expanded once for the
      # install/remove/upgrade commands below (see expand_dpkg_options).
      dpkg_opts = expand_dpkg_options

      case state
      when "present"
        if is_installed
          # Ansible 2.19.11 registered order (live-verified, `{{ r | to_json }}`
          # via package: on this apt host): changed, cache_updated,
          # cache_update_time - NO msg (the apt module's unchanged-present
          # exit is exit_json(changed=False, cache_updated=...,
          # cache_update_time=...); the "Package X already installed" msg
          # was this backend's own borrow).
          PluginResult.new(
            changed: false,
            failed: false,
            cache_updated: false,
            cache_update_time: apt_cache_mtime(->remote_exec(String)),
            key_order: %w[changed cache_updated cache_update_time]
          )
        else
          if @check_mode
            # Real apt's check-mode install runs the same command with
            # --simulate and registers the simulate run's own shape
            # (live-verified: changed, stdout, stderr, diff,
            # cache_updated, cache_update_time, stdout_lines,
            # stderr_lines); a name apt cannot resolve fails the task
            # with apt.py's own "No package matching 'X' is available"
            # (live-verified in check mode).
            sim = remote_exec("apt-get install --simulate #{shell_pkg} 2>&1")
            if sim[:exit_code] == 0
              return simulate_result(sim[:stdout], sim[:stderr])
            end
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "No package matching '#{name}' is available",
              rc: sim[:exit_code],
              stderr: sim[:stderr].empty? ? sim[:stdout] : sim[:stderr]
            )
          end

          install_result = apt_install_with_implicit_cache_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y #{dpkg_opts} #{shell_pkg}".squeeze(' '), lock_timeout, ->remote_exec(String))
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
            # changed: true - Ansible's own apt module (and this
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
          # Ansible 2.19.11 (live-verified via package: state=absent on a
          # not-installed name): a bare exit_json(changed=False) - no msg,
          # no cache keys (the absent-nochange exit skips them entirely).
          PluginResult.new(
            changed: false,
            failed: false,
            key_order: %w[changed]
          )
        else
          if @check_mode
            # Real apt's check-mode remove runs --simulate too and
            # registers the same simulate shape as the install side
            # (live-verified); an apt-get refusal (e.g. essential-package
            # protection) surfaces as run_command's failure shape.
            sim = remote_exec("apt-get remove --simulate #{shell_pkg} 2>&1")
            if sim[:exit_code] == 0
              return simulate_result(sim[:stdout], sim[:stderr])
            end
            stderr = sim[:stderr].empty? ? sim[:stdout] : sim[:stderr]
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "'apt-get remove #{shell_single_quote(shell_pkg)}' failed: #{stderr}",
              rc: sim[:exit_code],
              stdout: sim[:stdout],
              stderr: stderr
            )
          end

          remove_result = apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive apt-get remove -y #{dpkg_opts} #{shell_pkg}".squeeze(' '), lock_timeout, ->remote_exec(String))
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
        # `name: "*"` + `state: latest` - Ansible's apt.py (the backend
        # this module dispatches to on apt hosts) takes its OWN
        # `if latest and all_installed:` branch here and calls
        # upgrade(module, 'yes', ...): the same command `upgrade: yes`
        # builds, NEVER a per-package `apt-get install *`. apt-get
        # treats a bare `*` as a glob over EVERY package in the archive,
        # so on a host with a held/conflicting package pair it drags in
        # packages a real `apt-get upgrade` never touches (upgrade only
        # touches packages that need no install/remove) and fails
        # outright with "E: Unable to correct problems, you have held
        # broken packages" where Ansible reports a clean upgrade. Found
        # via MindPointGroup.ubuntu22_cis's own "1.2.2.1 | PATCH | Ensure
        # updates, patches, and additional security software are
        # installed" task (round 1500409) - the same defect this
        # engine's separate apt.cr already fixed for `apt:`
        # (handle_wildcard_latest); the two dispatches are independent
        # plugin binaries, so the handler is duplicated rather than
        # shared.
        if names.includes?("*")
          # apt.py's own fail_json message verbatim - Ansible refuses
          # to mix "*" with real package names rather than guessing
          # which one the caller meant.
          if names.size > 1
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "unable to install additional packages when upgrading all installed packages"
            )
          end
          return handle_apt_wildcard_latest(dpkg_opts, lock_timeout)
        end
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
        # entirely (exit 0, "0 upgraded, 0 newly installed") -
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
        # (Ansible silently recovers a corrupt on-disk index this
        # way - see apt_install_with_implicit_cache_retry; a plain
        # locate-miss on an otherwise-valid cache, e.g. `package:
        # {name: w3m, state: present}` against a merely-empty
        # /var/lib/apt/lists/, is NOT retried by ansible-playbook
        # either - it fails outright with "No package matching 'w3m' is
        # available").
        upgrade_result = apt_install_with_implicit_cache_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y #{dpkg_opts} #{shell_pkg}".squeeze(' '), lock_timeout, ->remote_exec(String))

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

    # apt.py's upgrade(module, 'yes', ...) - what `name: "*"` +
    # `state: latest` resolves to (see the gate in handle_apt). Command
    # shape is apt.py's own format string:
    # `apt-get -y <dpkg_options> <force> <fail_on_autoremove>
    # <allow_unauthenticated> <allow_downgrade> [<--simulate>]
    # upgrade --with-new-pkgs [<--auto-remove>] [< -t '<release>'>]`,
    # inside DEBIAN_FRONTEND=noninteractive like this module's other
    # apt-get calls. Result shape is apt.py's upgrade() exit:
    # exit_json(changed, msg=out, stdout=out, stderr=err, diff={}) or
    # its APT_GET_ZERO exit without diff, and fail_json(msg="'<cmd>'
    # failed: <err>", stdout=out, rc=rc) on a non-zero rc (mirrors
    # apt.cr's own handle_wildcard_latest - live-verified there).
    private def handle_apt_wildcard_latest(dpkg_opts : String, lock_timeout : Int32) : PluginResult
      autoremove = true?(@params["autoremove"]?) ? "--auto-remove" : ""
      upgrade_command = "upgrade --with-new-pkgs #{autoremove}"
      flags = [
        dpkg_opts,
        true?(@params["force"]?) ? "--force-yes" : "",
        true?(@params["fail_on_autoremove"]?) ? "--no-remove" : "",
        true?(@params["allow_unauthenticated"]?) ? "--allow-unauthenticated" : "",
        true?(@params["allow_downgrade"]?) ? "--allow-downgrades" : "",
        @check_mode ? "--simulate" : "",
      ].reject(&.empty?).join(" ")
      cmd = "#{apt_get_bin} -y #{flags} #{upgrade_command}"
      cmd += " -t '#{@params["default_release"]?}'" if @params["default_release"]?

      result = apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive #{cmd}".squeeze(' '), lock_timeout, ->remote_exec(String))
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "'#{apt_get_bin} #{upgrade_command}' failed: #{result[:stderr]}",
          stdout: result[:stdout],
          rc: result[:exit_code],
          key_order: ["stdout", "rc", "failed", "msg"]
        )
      end

      # apt.py's APT_GET_ZERO, leading-newline match so a summary whose
      # upgraded count ends in 0 doesn't false-match at an inner offset.
      zero_effect = result[:stdout].includes?("\n0 upgraded, 0 newly installed, 0 to remove")
      PluginResult.new(
        changed: !zero_effect,
        failed: false,
        msg: result[:stdout],
        stdout: result[:stdout],
        stderr: result[:stderr],
        diff: JSON.parse("{}"),
        key_order: zero_effect ? ["changed", "msg", "stdout", "stderr", "stdout_lines", "stderr_lines"] : ["changed", "msg", "stdout", "stderr", "diff", "stdout_lines", "stderr_lines"]
      )
    end

    # Real apt.py resolves apt-get through get_bin_path, so the absolute
    # path is what its "'<cmd>' failed" messages quote (mirrors apt.cr's
    # own resolver; falls back to the bare name when not found).
    private def apt_get_bin : String
      @apt_get_bin ||= begin
        probe = remote_exec("command -v apt-get")
        path = probe[:stdout].strip
        path.empty? ? "apt-get" : path
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

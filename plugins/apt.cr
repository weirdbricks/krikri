#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/apt_lock_retry"

module Krikri
  # APT Plugin - Debian/Ubuntu package management
  #
  # Parameters:
  #   name (optional): Package name or list of packages
  #   deb (optional): Path or URL to a local .deb file to install
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
    include AptLockRetry

    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # Real ansible's apt module on a non-Debian-family host: it first
      # auto-installs its python3-apt dependency ("Updating cache and
      # auto-installing missing dependency: python3-apt" warning) via
      # AnsibleModule.run_command, which fails ENOENT with exactly
      # {"changed": false, "cmd": "update", "msg": "Error executing
      # command.", "rc": 2} - observed live on Rocky 9.6 with Oefenweb.dns
      # (round 196). Without this guard this engine's dpkg-query-based
      # absent path quietly reported "Package ... not installed" rc=0.
      unless File.exists?("/usr/bin/apt-get") || File.exists?("/usr/local/bin/apt-get")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Error executing command.",
          cmd: "update",
          rc: 2
        )
      end

      # Real Ansible's apt module auto-installs the python3-apt bindings
      # (with an `apt-get update` prefetch) at module start when missing
      # and then respawns - see AptLockRetry#apt_auto_install_python_apt
      # for why this has to be a real, persistent host mutation rather
      # than a per-invocation emulation: without it a host that starts
      # without the bindings stays on the "absent → changed=false"
      # cache-refresh path forever instead of moving to the mtime-diff
      # path after the first apt task (found via geerlingguy.kubernetes,
      # rounds 65166/65311). Check mode skips this - real Ansible fails
      # fast in check mode instead (refusal mirrored inside the
      # update-cache block below, where it has always lived here).
      unless @check_mode
        explicitly_no_cache = @params["update_cache"]? ? !true?(@params["update_cache"]?) : false
        if failure = apt_auto_install_python_apt(explicitly_no_cache, ->remote_exec(String))
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to auto-install python3-apt: #{failure[:stderr]}"
          )
        end
      end

      # Get state (default: present)
      state = @params["state"]? || "present"
      update_cache = true?(@params["update_cache"]?)
      cache_valid_time = @params["cache_valid_time"]?.try(&.to_i) || 0
      # Real Ansible treats a bare `cache_valid_time: N` with NO name/
      # upgrade/deb as a cache-refresh-only invocation (apt.py's own
      # `if p['cache_valid_time']:` branch runs the update pass and
      # early-exits ok) - a common "keep the apt cache fresh" idiom
      # (riemers.gitlab-runner's "(Debian) Refresh package cache" task).
      # This plugin only recognized an explicit update_cache: true, so
      # the name-less form failed outright with "Missing required
      # parameter: name". cache_valid_time=0 is Python-falsy = absent,
      # matching apt.py exactly.
      has_cache_valid_time = cache_valid_time > 0
      # Real Ansible's apt module exposes `lock_timeout` (default 60s) for
      # install/remove/upgrade operations and `update_cache_retries`
      # (default 5) + `update_cache_retry_max_delay` (default 12s) for
      # `apt-get update`. Found missing in round 153 (2026-08-20) when a
      # fresh Atlantic.net Ubuntu host's unattended-upgr held the dpkg
      # lock during `apt:`; real Ansible's apt module waited up to 60s
      # for the lock and succeeded, krikri-playbook failed fast. See
      # `KNOWN_MISSING.md` / round 153 results for the full trace.
      # Wire the same parameter names here so user playbooks that
      # override them on either engine work identically.
      lock_timeout = @params["lock_timeout"]?.try(&.to_i) || 60
      update_cache_retries = @params["update_cache_retries"]?.try(&.to_i) || 5
      update_cache_retry_max_delay = @params["update_cache_retry_max_delay"]?.try(&.to_i) || 12

      changed = false
      messages = [] of String

      # Real Ansible's own apt.py only lets a cache refresh contribute to
      # the task's overall `changed:` when update_cache: is the ONLY
      # thing requested (`if not p['package'] and not p['upgrade'] and
      # not p['deb']: module.exit_json(changed=updated_cache, ...)`) -
      # once name:/upgrade:/deb: is ALSO given, the early-exit never
      # happens and `changed` is decided entirely by that package/
      # upgrade/deb operation's own result, regardless of whether the
      # cache itself needed refreshing. Previously this plugin OR'd the
      # cache-refresh's own `changed = true` into the same shared local
      # unconditionally, so `apt: {update_cache: true, upgrade: dist}`
      # always reported `changed: true` merely from refreshing the
      # package lists, even when the subsequent dist-upgrade genuinely
      # found "0 upgraded, 0 newly installed, 0 to remove" and real
      # Ansible correctly reported `ok`. Found benchmarking robertdebock.
      # update's own "Update all software (apt)" task.
      cache_update_is_sole_operation = !name_or_pkg_param? && !@params["upgrade"]? && !@params["deb"]?

      # Handle cache update
      if update_cache || has_cache_valid_time
        # Real Ansible's apt module cannot run at all in check mode when
        # it can't see the python3-apt bindings (its auto-install fallback
        # is a real mutation, so check mode fails fast instead) - mirror
        # that refusal. On hosts WITH python3-apt nothing changes here.
        if @check_mode && !python_apt_present?
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: AptLockRetry::CHECK_MODE_NO_PYTHON_APT_MSG
          )
        end
        if should_update_cache?(cache_valid_time)
          if @check_mode
            messages << "Would update apt cache"
            changed = true if cache_update_is_sole_operation
          elsif !python_apt_present?
            # Normal flow never reaches this branch - the module-start
            # auto-install above either puts the bindings in place or
            # fails the task, matching real Ansible's respawn. It is the
            # fallback for a host where the install "succeeded" but the
            # bindings still won't import. On a host WITHOUT python3-apt,
            # real Ansible auto-installs it
            # before its measurement window even opens - and that auto-install
            # step runs a full `apt-get update` first (apt.py's "Updating cache
            # and auto-installing missing dependency" path), then RESPAWNS the
            # module, so the before/after mtime pair is read entirely AFTER
            # that prefetch. A cache-refresh-only invocation therefore reports
            # `ok` on such hosts even when the prefetch genuinely fetched new
            # lists (verified live: deleting a lists file + aging the dir
            # mtime, real Ansible fetched - /var/lib/apt/lists's mtime moved -
            # and still reported changed=False while python3-apt was absent,
            # and changed=True once it was present). Since this plugin shells
            # out to the CLI and never installs python3-apt, emulate real
            # Ansible's observable behavior: run the update for its side
            # effects, but keep changed=false for the sole-operation case
            # regardless of mtime movement.
            update_result = apt_get_update_with_retry("apt-get update", update_cache_retries, update_cache_retry_max_delay, ->remote_exec(String))
            if update_result[:exit_code] == 0
              messages << "APT cache updated"
            else
              return PluginResult.new(
                changed: false,
                failed: true,
                msg: "Failed to update apt cache: #{update_result[:stderr]}"
              )
            end
          else
            # Real Ansible's apt module wraps the cache update with
            # `update_cache_retries` + `update_cache_retry_max_delay`
            # (defaults 5 and 12): retries on failure with exponential
            # backoff, doubled each attempt, capped at the max delay. We
            # approximate the same retry-on-lock-contention behavior;
            # non-lock errors (broken repo, network failure, signature
            # mismatch) still fail-fast on the first attempt.
            #
            # Real Ansible's own get_updated_cache_time() stats the same
            # update-success-stamp/lists-dir mtime BEFORE and AFTER
            # running the cache update, and only reports changed=true if
            # that mtime actually moved - with python3-apt present, both
            # python-apt's Cache().update() and the CLI `apt-get update`
            # leave the on-disk lists untouched when the upstream repo
            # content hasn't changed (conditional/hashsum-checked fetch;
            # verified live: an all-Hit `apt-get update` run does NOT
            # bump /var/lib/apt/lists's mtime), so a rerun against an
            # already-fresh mirror is a genuine no-op. This plugin
            # previously set changed=true unconditionally whenever it ran
            # the update as the sole operation, regardless of whether
            # anything on disk actually moved - found benchmarking
            # claranet.users's own "Update APT cache" task on a
            # freshly-imaged host (image already had a current cache from
            # build): py reported `ok`, cr `changed`.
            pre_update_mtime = cache_mtime
            update_result = apt_get_update_with_retry("apt-get update", update_cache_retries, update_cache_retry_max_delay, ->remote_exec(String))
            if update_result[:exit_code] == 0
              messages << "APT cache updated"
              post_update_mtime = cache_mtime
              changed = true if cache_update_is_sole_operation && post_update_mtime != pre_update_mtime
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
      name_param = name_or_pkg_param?
      autoremove = true?(@params["autoremove"]?)
      autoclean = true?(@params["autoclean"]?)
      clean = true?(@params["clean"]?)

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

          # `autoremove`/`autoclean` are apt-get operations that contend
          # for the dpkg lock - wrap with lock_timeout retry, matching
          # real Ansible's `apt` module behavior (see execute's param
          # parsing comment for the full trace).
          result = apt_with_lock_retry(cmd, lock_timeout, ->remote_exec(String))
          if result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true, msg: "#{cmd} failed: #{result[:stderr]}")
          end

          # Real Ansible's apt module checks for a specific marker
          # string in apt-get's own stdout, per operation
          # (CLEAN_OP_CHANGED_STR in apt.py) - NOT empty-vs-non-empty
          # output. `autoclean`/`autoremove` (and plain `apt-get
          # update`) print informational "Reading package lists..."
          # boilerplate to stdout unconditionally, whether or not
          # anything was actually removed, so the previous "non-empty
          # stdout means changed" heuristic always reported changed:
          # true for autoclean specifically. `clean:` (real Ansible's
          # own `aptclean()`) reports changed: true UNCONDITIONALLY
          # when called with no package/upgrade/deb - not based on
          # output at all.
          did_something = case cmd
                          when .includes?("autoremove")
                            result[:stdout].includes?("The following packages will be REMOVED")
                          when .includes?("autoclean")
                            result[:stdout].includes?("Del ")
                          else
                            true
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
          # `apt-get upgrade`/`dist-upgrade` contend for the dpkg lock -
          # wrap with lock_timeout retry (same rationale as the
          # autoremove/autoclean wrap above).
          result = apt_with_lock_retry(cmd, lock_timeout, ->remote_exec(String))
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

      # `deb:` - install a local .deb file (or a URL, downloaded first),
      # distinct from `name:` (a repository package name/version). Real
      # Ansible's apt module derives the package's own name+version from
      # the .deb's control metadata (`dpkg-deb -f`) to decide idempotency,
      # then installs via `apt-get install` (not a bare `dpkg -i`) so apt
      # resolves any of the .deb's own dependencies too. Entirely
      # unimplemented before - found via robertdebock.zabbix_repository's
      # own "Install (apt) repository" task (`apt: {deb: "{{
      # zabbix_repository_package }}"}`, round 18) - fell straight through
      # to the "no name: given" branch below and failed outright even
      # though a real install target (`deb:`) was given.
      deb_param = @params["deb"]?
      if deb_param
        return handle_deb(deb_param, messages, changed, lock_timeout)
      end

      # If no package name provided, just return cache update result
      unless name_param
        if update_cache || has_cache_valid_time || autoremove || autoclean || clean || upgrade
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
        handle_install(packages, messages, false, lock_timeout)
      when "absent"
        handle_remove(packages, messages, false, lock_timeout)
      when "latest"
        handle_latest(packages, messages, false, lock_timeout)
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be present, absent, or latest"
        )
      end
    end

    # `package:`/`pkg:` are documented aliases of `name:` for real
    # Ansible's apt module (`aliases: [package, pkg]`).
    private def name_or_pkg_param? : String?
      @params["name"]? || @params["package"]? || @params["pkg"]?
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

        # A Python-repr list (single-quoted strings, e.g.
        # `"['python3-apt', 'libcap2-bin']"`) isn't valid JSON, so the
        # parse above fails and previously fell through to the naive
        # comma-split, leaving the brackets/quotes stuck to the first/
        # last entries again ("['python3-apt", "libcap2-bin']"). This
        # shape comes from a Jinja `{% if %}...{% endif %}` template
        # whose only `{{ }}` is a literal list - real Ansible/Jinja2
        # renders that as the Python `str(list)` form, then Ansible's
        # own templating re-parses a whole-template result that looks
        # like a Python literal back into a real list (`ast.literal_
        # eval`-equivalent). Found live via prometheus.prometheus.
        # blackbox_exporter's own `_blackbox_exporter_dependencies:
        # "{% if ... %}{{ [...] }}{% endif %}"`. Naive but safe for the
        # common case (no embedded quotes/escapes in element strings,
        # true for every real caller so far): swap single quotes for
        # double and retry as JSON.
        parsed = begin
          Array(String).from_json(trimmed.gsub('\'', '"'))
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

    # One `dpkg-query` round trip for the WHOLE package list instead of
    # one `dpkg -l <pkg>` per package (N+1 remote commands on every
    # multi-package apt task). Returns installed-ness and the installed
    # version per requested base name; a name dpkg has never heard of
    # (never installed) simply has no line. Keys are the bare name with
    # any `:arch` suffix dpkg-query appends for multi-arch packages
    # stripped.
    private def dpkg_installed_status(packages : Array(String)) : Hash(String, {Bool, String?})
      statuses = Hash(String, {Bool, String?}).new
      return statuses if packages.empty?

      name_list = packages.map { |pkg| shell_single_quote(split_name_version(pkg)[0]) }.join(" ")
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

    # Handle `deb:` - install a local .deb file or a URL (downloaded to a
    # temp path first). Idempotency mirrors real Ansible's own apt module:
    # read the package's own name+version out of the .deb's control
    # metadata via `dpkg-deb -f`, and skip the install if that exact
    # name/version is already installed.
    private def handle_deb(deb_source : String, messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      path = deb_source

      if deb_source.starts_with?("http://") || deb_source.starts_with?("https://")
        path = "/tmp/#{File.basename(deb_source).split('?').first}"

        if @check_mode
          messages << "Would download #{deb_source} to #{path}"
        else
          download_result = remote_exec("curl -fsSL -o #{shell_single_quote(path)} #{shell_single_quote(deb_source)}")
          if download_result[:exit_code] != 0
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to download #{deb_source}: #{download_result[:stderr]}"
            )
          end
        end
      end

      # Read the .deb's own control metadata to find its real package
      # name/version, the same identity real Ansible's apt module checks
      # against dpkg's installed-package database for idempotency.
      info_result = remote_exec("dpkg-deb -f #{path} Package Version")
      if info_result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read package metadata from #{path}: #{info_result[:stderr]}"
        )
      end

      pkg_name = nil
      pkg_version = nil
      info_result[:stdout].each_line do |line|
        if line.starts_with?("Package:")
          pkg_name = line.sub("Package:", "").strip
        elsif line.starts_with?("Version:")
          pkg_version = line.sub("Version:", "").strip
        end
      end

      if pkg_name && pkg_version
        check_result = remote_exec("dpkg -l #{pkg_name} 2>/dev/null | grep '^ii'")
        if check_result[:exit_code] == 0 && installed_version(check_result[:stdout]) == pkg_version
          return PluginResult.new(changed: false, failed: false, msg: "#{pkg_name} already at version #{pkg_version}")
        end
      end

      if @check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would install #{path}")
      end

      # `apt-get install` of a .deb contends for the dpkg lock - wrap
      # with lock_timeout retry, matching real Ansible's behavior.
      install_result = apt_with_lock_retry("apt-get -y install #{path}", lock_timeout, ->remote_exec(String))
      if install_result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to install #{path}: #{install_result[:stderr]}"
        )
      end

      PluginResult.new(changed: true, failed: false, msg: "Installed #{pkg_name || path}", stdout: install_result[:stdout])
    end

    # Handle installing packages
    private def handle_install(packages : Array(String), messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      to_install = [] of String
      already_installed = [] of String
      install_stdout = ""
      install_stderr = ""

      # Check which packages need installation - one batched query for
      # the whole list (see dpkg_installed_status).
      installed_status = dpkg_installed_status(packages)
      packages.each do |pkg|
        base_name, pinned_version = split_name_version(pkg)
        installed, installed_ver = installed_status[base_name]?.try { |pair| pair } || {false, nil}
        if installed && (pinned_version.nil? || installed_ver == pinned_version)
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
          # `apt-get install` of named packages contends for the dpkg lock
          # - wrap with lock_timeout retry, matching real Ansible's
          # `apt` module behavior. The DEBIAN_FRONTEND=noninteractive +
          # force-confdef/force-confold flags carry over verbatim; the
          # retry layer only governs lock contention and leaves the
          # actual install behavior untouched. Also wraps real Ansible's
          # implicit recovery from a corrupt/unparseable on-disk package
          # index: on that specific failure (not a plain locate-miss on
          # a valid cache) the whole install is retried once behind an
          # implicit `apt-get update` (see
          # apt_install_with_implicit_cache_retry).
          install_cmd = "DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold #{pkg_list}"
          install_result = apt_install_with_implicit_cache_retry(install_cmd, lock_timeout, ->remote_exec(String))
          install_stdout = install_result[:stdout]
          install_stderr = install_result[:stderr]
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

      # Real Ansible's ansible.builtin.apt module always registers a
      # `stdout`/`stderr` key (the underlying apt-get invocation's raw
      # output, "" when no apt-get command actually ran) - some roles
      # register this task and inspect `.stdout` afterwards (found via
      # claranet.postgresql's own `when: ... in
      # _postgresql_packages_installation_res.stdout` checking apt's own
      # postinst-trigger output for whether the just-installed postgres
      # package auto-created a cluster). Without it, that `when:` failed
      # outright ("object of type 'dict' has no attribute 'stdout'")
      # instead of evaluating the condition like real Ansible does.
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        stdout: install_stdout,
        stderr: install_stderr
      )
    end

    # Handle removing packages
    private def handle_remove(packages : Array(String), messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      to_remove = [] of String
      already_absent = [] of String

      # Check which packages need removal - state: absent removes by
      # NAME regardless of any `=version` pin (matching real apt-get
      # remove semantics), so only the base name is checked here. One
      # batched query for the whole list (see dpkg_installed_status).
      installed_status = dpkg_installed_status(packages)
      packages.each do |pkg|
        base_name, _ = split_name_version(pkg)
        installed, _ = installed_status[base_name]?.try { |pair| pair } || {false, nil}
        if installed
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
          # `apt-get remove` contends for the dpkg lock - wrap with
          # lock_timeout retry, matching real Ansible's behavior.
          remove_result = apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive apt-get remove -y #{pkg_list}", lock_timeout, ->remote_exec(String))
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
    private def handle_latest(packages : Array(String), messages : Array(String), changed : Bool, lock_timeout : Int32) : PluginResult
      if @check_mode
        # `grep -i upgrade` matched the ALWAYS-present "N upgraded, M newly
        # installed" summary line of simulate output, so check mode never
        # converged to ok. `^Inst` only matches an actual install/upgrade
        # action line.
        check_cmds = packages.map { |pkg| "apt-get install --simulate #{shell_single_quote(pkg)} 2>&1 | grep '^Inst'" }
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
        # `state: latest` (apt-get install for upgrade-or-install)
        # contends for the dpkg lock - wrap with lock_timeout retry,
        # plus the same implicit cache-update retry on corrupt/
        # unparseable lists that handle_install above gets.
        upgrade_result = apt_install_with_implicit_cache_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold #{pkg_list}", lock_timeout, ->remote_exec(String))

        # apt-get exits 100 when a package can't be located at all
        # ("E: Unable to locate package sensu" - e.g. a repo that carries
        # no candidate for this release). That's a hard failure the way
        # real Ansible's apt module fails with "No package matching X is
        # available", NOT a clean "already at latest" - the previous code
        # fell through to success here (found via buluma.sensu-install,
        # where packagecloud's sensu/stable repo has no jammy candidate).
        if upgrade_result[:exit_code] != 0
          return PluginResult.new(
            changed: changed,
            failed: true,
            msg: "Failed to install latest: #{upgrade_result[:stderr]}"
          )
        end

        # "N upgraded, M newly installed, ..." is apt's own reliable,
        # locale-stable summary line - checking for the English phrase
        # "already the newest version" (the previous approach) missed
        # the "not installed and only upgrades are requested" case
        # entirely (a different message, so the check wrongly concluded
        # something HAD changed).
        summary = upgrade_result[:stdout][/(\d+) upgraded, (\d+) newly installed/]?
        was_upgraded = summary ? summary.scan(/\d+/).sum(&.[0].to_i) > 0 : upgrade_result[:exit_code] == 0
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

      # Real Ansible's apt.py checks /var/lib/apt/periodic/update-success-
      # stamp's mtime if present (written by APT::Periodic's own update
      # timer/unattended-upgrades), else falls back to the /var/lib/apt/
      # lists DIRECTORY's own mtime. This previously stat'd /var/lib/apt/
      # lists/partial instead - a transient staging dir apt-get update
      # barely touches, not a real freshness signal - so its mtime stayed
      # old (image-build time) and `age > cache_valid_time` was almost
      # always true, refreshing (and reporting changed: true for) a cache
      # real Ansible correctly saw as still valid and left alone. Found
      # benchmarking Stouts.apt's own "Update apt cache" task (default
      # apt_cache_valid_time: 3600) - py reported `ok`, cr `changed`.
      last_update = cache_mtime
      current_time = Time.utc.to_unix

      age = current_time - last_update
      age > cache_valid_time
    end

    # Thin wrappers over AptLockRetry's own shared `apt_cache_mtime`/
    # `apt_python_apt_present?` (see there) - kept here, at the same
    # names/signatures every call site above already used, so this is
    # the only file that changed when the logic moved to the shared
    # module. One implementation now backs both this plugin and
    # package.cr's own cache-refresh-only path - see AptLockRetry's own
    # comment for why that single-source-of-truth matters (this exact
    # class of duplicate-implementation drift is what caused
    # robertdebock.update_package_cache's regression).
    private def cache_mtime : Int32
      apt_cache_mtime(->remote_exec(String))
    end

    private def python_apt_present? : Bool
      apt_python_apt_present?(->remote_exec(String))
    end

    # Helper to convert string/bool to boolean
    # The lock-contention retry helpers (apt_with_lock_retry,
    # apt_get_update_with_retry, apt_lock_held?) live in
    # `src/krikri/plugin_helpers/apt_lock_retry.cr` and are
    # mixed in via `include AptLockRetry` at the top of this class -
    # one canonical implementation, exercised by the regression spec
    # without needing the plugin's entry point.
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::AptPlugin.new(config)
plugin.run

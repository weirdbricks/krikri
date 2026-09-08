module Krikri
  # Helpers for the `apt` plugin's dpkg-lock-contention retry behavior
  # (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #1 follow-on, 0.9.502).
  #
  # Round 153 (2026-08-20) found that krikri-playbook's `apt:` module
  # failed fast when the host's dpkg lock was held by another process
  # (Ubuntu's unattended-upgr, an in-progress apt on another shell, etc.)
  # while real Ansible's apt module waited it out via `lock_timeout: 60`
  # (default). Same parameter names here so playbooks that override
  # them on either engine work identically.
  #
  # These helpers are mixed into AptPlugin via the `extend`/`include`
  # mechanism below so AptPlugin can call them as private methods
  # (`apt_with_lock_retry`, `apt_get_update_with_retry`,
  # `apt_lock_held?`) without exposing them publicly, while still
  # letting the regression spec require this file directly without
  # firing apt.cr's entry point. The spec exercises the retry logic
  # through this module by stubbing `remote_exec` on a test subclass
  # of AptPlugin.
  module AptLockRetry
    # Default for install/remove/upgrade operations - matches real
    # Ansible's `apt` module default.
    DEFAULT_LOCK_TIMEOUT = 60

    # Defaults for `apt-get update` - match real Ansible's `apt` module
    # defaults exactly.
    DEFAULT_UPDATE_CACHE_RETRIES         =  5
    DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY = 12

    # Detects the dpkg/apt lock contention stderr patterns that
    # `apt-get` itself emits. Matches real Ansible's python-apt-based
    # wait/retry detection (which checks the same three patterns on
    # `OSError` from apt's `cache_lock`/`system_lock`). Conservative:
    # any other stderr fails fast, even if it's "lock-related", so
    # bogus lock messages don't trigger an infinite retry.
    def apt_lock_held?(stderr : String) : Bool
      stderr.includes?("Could not get lock /var/lib/dpkg/lock-frontend") ||
        stderr.includes?("Unable to acquire the dpkg frontend lock") ||
        stderr.includes?("/var/lib/dpkg/lock")
    end

    # Matches real Ansible's `apt` module's `lock_timeout` retry behavior
    # on install/remove/upgrade operations. Only retries when stderr
    # indicates dpkg lock contention - other failures (broken repo,
    # missing package, signature mismatch) fail-fast on the first
    # attempt, matching real Ansible's selective-retry behavior.
    #
    # Sleeps in 3-second increments between attempts - bounds total
    # controller-fiber blocking time across multiple retries, well
    # within the user-visible `lock_timeout`. Returns the last
    # lock-holding error when the budget is exhausted, exactly the
    # way real Ansible's apt module does.
    def apt_with_lock_retry(cmd : String, lock_timeout : Int32,
                            exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      start = Time.monotonic
      loop do
        result = exec_remote.call(cmd)
        return result if result[:exit_code] == 0 || !apt_lock_held?(result[:stderr])

        elapsed = (Time.monotonic - start).total_seconds.to_i
        if elapsed >= lock_timeout
          return result
        end

        sleep_for = Math.min(3, lock_timeout - elapsed)
        ::sleep(sleep_for.seconds)
      end
    end

    # Matches real Ansible's `apt` module's `update_cache_retries` +
    # `update_cache_retry_max_delay` on `apt-get update`. Exponential
    # backoff starting at 1s, doubled each attempt, capped at
    # `retry_max_delay`. Only retries on lock contention - other
    # apt-get update failures (broken repo, network) fail-fast,
    # matching real Ansible's selective-retry behavior.
    def apt_get_update_with_retry(cmd : String, retries : Int32, retry_max_delay : Int32,
                                  exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      delay = 1
      result = exec_remote.call(cmd)
      return result if result[:exit_code] == 0 || !apt_lock_held?(result[:stderr])

      retries.times do
        ::sleep(delay.seconds)
        delay = Math.min(delay * 2, retry_max_delay)
        result = exec_remote.call(cmd)
        return result if result[:exit_code] == 0 || !apt_lock_held?(result[:stderr])
      end

      result
    end

    # Detects the CLI-observable signature of a genuinely corrupt/
    # unparseable on-disk package index - NOT a plain "package doesn't
    # exist in an otherwise-valid cache" miss.
    #
    # Real Ansible's apt module (python-apt-backed) only retries when
    # `apt.Cache()` itself raises a `SystemError` whose message mentions
    # `/var/lib/apt/lists/` (`get_cache()` in ansible's `apt.py`) - that
    # is specifically a cache *open/parse* failure (corrupt or
    # unreadable index files), not "no candidate for this name". A
    # simple locate-miss on a valid-but-empty or valid-but-outdated
    # cache does NOT trigger it: `package_status()` fails straight to
    # `fail_json("No package matching '%s' is available")` with no
    # retry at all - confirmed live (0.9.737) against a genuinely empty
    # `/var/lib/apt/lists/`, where real ansible-playbook failed outright
    # on `package: {name: w3m, state: present}` with that exact message
    # and krikri (this helper's previous, over-broad
    # "Unable to locate package" gate) silently installed it instead - a
    # real divergence the previous gate introduced rather than fixed.
    #
    # The corrupt-lists SystemError's apt-get-CLI equivalent was
    # confirmed live by corrupting a downloaded index file (an
    # unreadable `.lz4` list) and reproducing the exact python-apt
    # exception text via both `apt.Cache()` directly and
    # `apt-get install`: `E: The package lists or status file could not
    # be parsed or opened.` - genuinely different from, and much
    # narrower than, "Unable to locate package".
    def apt_corrupt_lists?(stderr : String) : Bool
      stderr.includes?("The package lists or status file could not be parsed or opened")
    end

    # Same mtime probe real Ansible's `get_cache_mtime()`/
    # `get_updated_cache_time()` use: the update-success-stamp if
    # present, else the /var/lib/apt/lists directory's own mtime.
    # Shared between apt.cr's own before/after cache-update comparison
    # and this module's own `should_update_cache?` (see there).
    def apt_cache_mtime(exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      result = exec_remote.call(
        "stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || " \
        "stat -c %Y /var/lib/apt/lists 2>/dev/null || echo 0"
      )
      result[:stdout].strip.to_i
    end

    # Can the target's Python see the python3-apt bindings? Same two
    # interpreters real Ansible's apt module probes
    # (probe_interpreters_for_module(['/usr/bin/python3', '/usr/bin/python'],
    # 'apt')) before deciding whether to auto-install python3-apt and
    # respawn under an interpreter that can see it - see apt.cr's own
    # `#execute` for the long comment on which changed-reporting path
    # that decides.
    def apt_python_apt_present?(exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      result = exec_remote.call(
        "/usr/bin/python3 -c 'import apt' 2>/dev/null || " \
        "/usr/bin/python -c 'import apt' 2>/dev/null"
      )
      result[:exit_code] == 0
    end

    # Emulates real Ansible's apt module module-start auto-install of the
    # python3-apt bindings (apt.py's probe_interpreters_for_module +
    # "Updating cache and auto-installing missing dependency" path): a
    # real, PERSISTENT host mutation that changes every later apt
    # invocation's changed-reporting path. When the bindings are missing
    # this runs the same `apt-get update` prefetch (skipped only when the
    # task explicitly passed update_cache: false, per apt.py's own
    # `if module.params.get('update_cache') is False` guard), then
    # `apt-get install -y python3-apt`, exactly the two commands real
    # Ansible runs before respawning itself. Returns nil when the
    # bindings were already present (a no-op) or the install succeeded;
    # returns the failed command result when either command failed,
    # mirroring real Ansible's check_rc=True hard failure.
    #
    # This engine previously only emulated the FIRST invocation's
    # observable `changed` behavior (the round-30001 rule) without ever
    # performing the install, so a host that started without the
    # bindings stayed on the "absent → changed=false" cache-refresh path
    # forever, while real Ansible moved to the mtime-diff path after its
    # very first apt task. Found via geerlingguy.kubernetes (rounds
    # 65166/65311): the role's "Ensure dependencies are installed." task
    # triggers real Ansible's auto-install, so its later "Update Apt
    # cache." task (immediately after deb822_repository added the
    # pkgs.k8s.io repo, whose freshly-fetched indexes genuinely move the
    # lists mtime) reported changed=true there, while this engine stayed
    # on the absent path and reported ok.
    def apt_auto_install_python_apt(skip_prefetch : Bool,
                                    exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String))) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)?
      return nil if apt_python_apt_present?(exec_remote)

      unless skip_prefetch
        result = exec_remote.call("apt-get update")
        return result if result[:exit_code] != 0
      end

      result = exec_remote.call("apt-get install -y python3-apt")
      return result if result[:exit_code] != 0
      nil
    end

    # Real Ansible's apt module cannot run at all in check mode when it
    # can't see the python3-apt bindings: its auto-install fallback
    # (apt_auto_install_python_apt above) is a real, PERSISTENT host
    # mutation, and check mode must never mutate the target - so the
    # module fails fast with this exact message instead. Shared between
    # apt.cr's own update-cache block and package.cr's cache-refresh-only
    # path (real `package:` delegates to the apt module on apt hosts, so
    # it refuses identically) rather than duplicating the literal in two
    # places and letting them drift.
    CHECK_MODE_NO_PYTHON_APT_MSG = "python3-apt must be installed to use check mode. If run normally this module can auto-install it, see the auto_install_module_deps option."

    # Returns the refusal message above when a check-mode run must fail
    # because the bindings are absent, else nil (not check mode, or the
    # bindings are already there and nothing needs installing).
    def apt_check_mode_python_apt_refusal(check_mode : Bool,
                                          exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String))) : String?
      return nil unless check_mode
      return nil if apt_python_apt_present?(exec_remote)
      CHECK_MODE_NO_PYTHON_APT_MSG
    end

    # Real Ansible's `changed` semantics for a cache-refresh-ONLY apt
    # invocation (no name:/upgrade:/deb: alongside it): WITHOUT
    # python3-apt, real Ansible auto-installs it before its own
    # measurement window opens (that auto-install runs a full `apt-get
    # update` first, then respawns and reads mtime entirely AFTER the
    # prefetch) - so it always reports `changed: false` here regardless
    # of whether anything was actually fetched. WITH python3-apt, it
    # reports `changed: true` only if the cache mtime genuinely moved.
    # See apt.cr's own `#execute` for the live verification this
    # mirrors (round 30001) - shared here so `package:`'s own
    # cache-refresh path (`update_cache: true` with no `name:`) doesn't
    # duplicate-and-drift from this logic the way it previously did
    # (found via robertdebock.update_package_cache: this engine
    # hardcoded `changed: true` for apt unconditionally, real Ansible's
    # `ok`/`changed: false` on an already-fresh mirror).
    def apt_cache_refresh_changed?(pre_mtime : Int32, post_mtime : Int32,
                                   exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      return false unless apt_python_apt_present?(exec_remote)
      post_mtime != pre_mtime
    end

    # Real Ansible's apt module silently recovers from an install
    # failure caused by a corrupt/unparseable on-disk package index:
    # `get_cache()` catches the `apt.Cache()` `SystemError` and retries
    # `apt-get update` (up to twice) before re-opening the cache. Only
    # retries ONCE here, and only on the corrupt-lists stderr pattern -
    # any other failure (broken repo, signature mismatch, a plain
    # locate-miss on a valid cache, a held lock that outlives
    # `lock_timeout`) fails fast exactly as before. Returns the retry
    # result when the refresh helped, else the original failure.
    def apt_install_with_implicit_cache_retry(cmd : String, lock_timeout : Int32,
                                              exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      result = apt_with_lock_retry(cmd, lock_timeout, exec_remote)
      return result if result[:exit_code] == 0 || !apt_corrupt_lists?(result[:stderr])

      update_result = exec_remote.call("apt-get update")
      return result if update_result[:exit_code] != 0

      exec_remote.call(cmd)
    end
  end
end

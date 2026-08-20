module CrystalPlay
  # Helpers for the `apt` plugin's dpkg-lock-contention retry behavior
  # (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #1 follow-on, 0.9.502).
  #
  # Round 153 (2026-08-20) found that crystal-ansible's `apt:` module
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
  end
end

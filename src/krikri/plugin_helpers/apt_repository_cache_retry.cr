module Krikri
  # Cache-update retry behavior for the `apt_repository` plugin, mirroring
  # real Ansible's own `apt_repository.py` `update_cache_retries` /
  # `update_cache_retry_max_delay` parameters (defaults 5 / 12, both
  # verified against the locally installed module's argument_spec).
  #
  # Real Ansible's loop (apt_repository.py, `if update_cache:` block):
  # `for retry in range(update_cache_retries)` around python-apt's
  # `Cache().update()`, with `delay = 2 ** retry + randomize` between
  # attempts (`randomize = secrets.randbelow(1000) / 1000.0`), the delay
  # capped at `update_cache_retry_max_delay + randomize` when the
  # exponential term outgrows it. Same formula here.
  #
  # Mixed into AptRepositoryPlugin so the retry loop is callable as a
  # private method, while the regression spec can require this file
  # directly (without firing apt_repository.cr's entry point) and drive
  # the loop through an injected `exec_remote` proc - the same pattern
  # AptLockRetry established for the `apt` plugin's own
  # update_cache_retries support.
  module AptRepositoryCacheRetry
    DEFAULT_UPDATE_CACHE_RETRIES         =  5
    DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY = 12

    # Backoff delay before retry number *retry* (0-based), matching real
    # Ansible's `delay = 2 ** retry + randomize` capped at
    # `update_cache_retry_max_delay + randomize`. *jitter* is injectable
    # so the regression spec can pin the value; defaults to the same
    # 0..1 random fraction real Ansible uses.
    def apt_repository_retry_delay(retry : Int32, max_delay : Int32, jitter : Float64 = Random.rand(1000) / 1000.0) : Float64
      delay = 2.0 ** retry + jitter
      delay = max_delay + jitter if delay > max_delay
      delay
    end

    # Runs `apt-get update`, retrying on non-zero exit up to *retries*
    # total attempts (real Ansible's `range(update_cache_retries)` bound)
    # with the exponential-backoff-with-jitter delay between attempts.
    #
    # Only a non-zero exit code retries: that maps to apt's own fetch
    # failure, the case python-apt reports as FetchFailedException (the
    # only exception real Ansible's loop catches). A GPG signature
    # warning leaves `apt-get update` exiting 0 - that path is handled
    # separately by the plugin's gpg_signature_failure? scan and, like
    # real Ansible's non-FetchFailedException exceptions, fails without
    # retrying.
    def apt_repository_cache_update_with_retry(retries : Int32, max_delay : Int32,
                                               exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      result = exec_remote.call("apt-get update")
      attempt = 0
      while result[:exit_code] != 0 && attempt < retries - 1
        ::sleep(apt_repository_retry_delay(attempt, max_delay).seconds)
        attempt += 1
        result = exec_remote.call("apt-get update")
      end
      result
    end
  end
end

require "./apt_repository_cache_retry"

module Krikri
  # Helpers for the `apt` plugin's dpkg-lock-contention retry behavior
  # (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #1 follow-on, 0.9.502).
  #
  # Round 153 (2026-08-20) found that krikri-playbook's `apt:` module
  # failed fast when the host's dpkg lock was held by another process
  # (Ubuntu's unattended-upgr, an in-progress apt on another shell, etc.)
  # while Ansible's apt module waited it out via `lock_timeout: 60`
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
    # Default for install/remove/upgrade operations - matches
    # Ansible's `apt` module default.
    DEFAULT_LOCK_TIMEOUT = 60

    # Defaults for `apt-get update` - match Ansible's `apt` module
    # defaults exactly.
    DEFAULT_UPDATE_CACHE_RETRIES         =  5
    DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY = 12

    # Detects the dpkg/apt lock contention stderr patterns that
    # `apt-get` itself emits. Matches Ansible's python-apt-based
    # wait/retry detection (which checks the same three patterns on
    # `OSError` from apt's `cache_lock`/`system_lock`). Conservative:
    # any other stderr fails fast, even if it's "lock-related", so
    # bogus lock messages don't trigger an infinite retry.
    def apt_lock_held?(stderr : String) : Bool
      stderr.includes?("Could not get lock /var/lib/dpkg/lock-frontend") ||
        stderr.includes?("Unable to acquire the dpkg frontend lock") ||
        stderr.includes?("/var/lib/dpkg/lock")
    end

    # Matches Ansible's `apt` module's `lock_timeout` retry behavior
    # on install/remove/upgrade operations. Only retries when stderr
    # indicates dpkg lock contention - other failures (broken repo,
    # missing package, signature mismatch) fail-fast on the first
    # attempt, matching Ansible's selective-retry behavior.
    #
    # Sleeps in 3-second increments between attempts - bounds total
    # controller-fiber blocking time across multiple retries, well
    # within the user-visible `lock_timeout`. Returns the last
    # lock-holding error when the budget is exhausted, exactly the
    # way Ansible's apt module does.
    def apt_with_lock_retry(cmd : String, lock_timeout : Int32,
                            exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)),
                            sleeper : Proc(Time::Span, Nil)? = nil)
      start = Time.instant
      loop do
        result = exec_remote.call(cmd)
        return result if result[:exit_code] == 0 || !apt_lock_held?(result[:stderr])

        elapsed = (Time.instant - start).total_seconds.to_i
        if elapsed >= lock_timeout
          return result
        end

        sleep_for = Math.min(3, lock_timeout - elapsed)
        if sl = sleeper
          sl.call(sleep_for.seconds)
        else
          retry_sleep(sleep_for)
        end
      end
    end

    # Matches Ansible's `apt` module's `update_cache_retries` +
    # `update_cache_retry_max_delay` on `apt-get update`. Exponential
    # backoff starting at 1s, doubled each attempt, capped at
    # `retry_max_delay`. Only retries on lock contention - other
    # apt-get update failures (broken repo, network) fail-fast,
    # matching Ansible's selective-retry behavior.
    def apt_get_update_with_retry(cmd : String, retries : Int32, retry_max_delay : Int32,
                                  exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      delay = 1
      result = exec_remote.call(cmd)
      return result if result[:exit_code] == 0 || !apt_lock_held?(result[:stderr])

      retries.times do
        retry_sleep(delay)
        delay = Math.min(delay * 2, retry_max_delay)
        result = exec_remote.call(cmd)
        return result if result[:exit_code] == 0 || !apt_lock_held?(result[:stderr])
      end

      result
    end

    # The helpers' inter-attempt sleep, scaled by KRIKRI_TEST_SLEEP_SCALE
    # when the environment sets it (e.g. "0.01"). Test-only: the suite's
    # retry-exhaustion specs exercise the retry/booking logic, not the
    # wall-clock backoff, and without the scale they pay the real 1-3s
    # sleeps per attempt. Unset (production), this is an exact ::sleep.
    # A zero/garbage scale makes the loops spin with no backoff, so it
    # must only ever be set around stub-command tests.
    private def retry_sleep(seconds : Float64) : Nil
      if scale = ENV["KRIKRI_TEST_SLEEP_SCALE"]?
        seconds *= scale.to_f
      end
      ::sleep(seconds.seconds)
    end

    # python-apt's Cache.update() - what real apt.py's update_cache pass
    # actually runs - raises a bare FetchFailedException() the moment ANY
    # acquire item failed, while the CLI `apt-get update` this plugin
    # shells out to treats that same partial failure as WARNING-level and
    # still exits 0 (verified on jammy's apt 2.4: a sources.list.d entry
    # pointing at an unresolvable host prints "W: Failed to fetch ..." /
    # "W: Some index files failed to download." and exits 0 - even when it
    # is the only configured source). Trusting the exit code alone made
    # `update_cache: true` against a bogus repo report success where
    # Ansible fails after its retries (round 1100002 kop_apt_fail
    # apt_fail_bogus_source). The CLI-observable equivalent of
    # python-apt's "res == failed" check is the failed-item markers apt
    # itself prints: an `Err:` line per failed item plus the W: summary.
    # python-apt raises ONLY on a failed item - the E:/Err: markers; a
    # warning-only line (a standalone "W: GPG error ... NO_PUBKEY ..."
    # with no failed item) exits 0 and python-apt raises nothing, so the
    # update succeeds just as real ansible reports it changed.
    def apt_fetch_failed?(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : Bool
      combined = "#{result[:stdout]}#{result[:stderr]}"
      combined.includes?("Err:") ||
        combined.includes?("W: Failed to fetch") ||
        combined.includes?("W: Some index files failed to download") ||
        apt_fetch_signature_failure?(result)
    end

    # The SECOND FetchFailedException shape python-apt raises:
    # `raise FetchFailedException(e)` around the SystemError apt_pkg throws
    # for repository-level errors, which the CLI surfaces as a top-level
    # "E:" diagnostic line ("E: The repository ... is not signed.").
    # python-apt raises only on a failed item, and a top-level E: line is
    # exactly how a failed item prints, so the E: form is the whole
    # detection. Every warning-only shape exits 0 and must succeed, the
    # same changed outcome real ansible reports: a standalone "W: GPG
    # error ... NO_PUBKEY ..." line raises nothing, and the W: form of
    # the unsigned-repo message (apt's allow-insecure path, "W: The
    # repository ... is not signed.") likewise never marks the update
    # failed. Unlike the bare `raise FetchFailedException()` a plain
    # network fetch failure takes, this shape CARRIES the diagnostic
    # lines as its str() text, so the retry warnings and the final
    # failure message quote them (round 5210000, artem_shestakov.nginx:
    # real ansible-core 2.19.11 warned five times with the GPG/E: text
    # and failed with "Failed to update apt cache after 5 retries:
    # W:... , E:..." while krikri classified the case as a plain
    # nonzero-exit failure and failed fast).
    def apt_fetch_signature_failure?(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : Bool
      combined = "#{result[:stdout]}\n#{result[:stderr]}"
      # A bare top-level "E: " diagnostic line is python-apt's
      # SystemError-wrapped shape - EXCEPT the lock-contention one
      # ("E: Could not get lock /var/lib/dpkg/lock-frontend ..."), which
      # apt-lock_held? already owns and which the caller's
      # (exit==0 || !lock_held) gate excludes anyway; classifying it as a
      # fetch failure would retry lock contention as if the repo were
      # broken.
      combined.split('\n').any? do |line|
        (line.starts_with?("E: ") || line.starts_with?("E:")) &&
          !line.includes?("lock")
      end
    end

    # The str() text of python-apt's SystemError-wrapped FetchFailedException:
    # the W:/E: diagnostic lines of that update attempt, with the space
    # after the letter marker stripped (python-apt reports "W:GPG error ...",
    # the CLI prints "W: GPG error ..." - verified live in a jammy container:
    # attempt 0's exception text was exactly the two CLI W:/E: lines so
    # transformed), joined with ", ". Empty for the bare-exception class
    # (plain fetch failures), whose warnings and final msg stay empty - the
    # round-1100002-verified shape.
    #
    # Every REFUSED repo ("E: The repository ..." - apt's
    # MessageInsecureRepository pushes the refusal error followed by the
    # same two untrusted-repo notices, which python-apt reports as W:
    # entries) has its pair directly after its refusal line - but the
    # notices that end up at the very tail of the text are trimmed from
    # it, so a refusal that is the text's LAST line carries no pair at
    # all (probed live on noble and trixie: a single missing-Release repo
    # quotes just its E: line, while round 29903261's
    # marauderxtreme.local_system - a missing-Release repo whose text ends
    # on git-core's legacy-keyring warning - quotes "E:..., W:Updating...,
    # W:See..., W:keyring..." on all five attempts). The CLI stderr
    # carries the same W:/E: lines with NO untrusted-repo lines at all,
    # so re-insert the pair after every refusal line and drop it again
    # when it lands at the tail.
    #
    # Tolerated shapes carry no refusal line - a [trusted=yes] repo's
    # standalone "W: GPG error ..." warning, allow-insecure W: warnings,
    # plain index 404s - and gain no pair anywhere (issue #665's repo
    # family, live-verified: python-apt joins those lines directly, the
    # two GPG lines sitting adjacent). The clearsigned shape (issue
    # #712) prints an "E: The repository ... is not signed." line but
    # through a path that pushes no untrusted-repo notices at all (real
    # ansible quotes it bare on all five attempts), and
    # apt_fetch_reason_refused_repo? counts it as not-refused, so it
    # gains no pair either.
    def apt_fetch_failure_reason(result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : String
      return "" unless apt_fetch_signature_failure?(result)
      combined = "#{result[:stdout]}\n#{result[:stderr]}"
      lines = combined.split('\n').select { |line| line.starts_with?("W:") || line.starts_with?("E:") }
        .map(&.sub(/\A([WE]): /, "\\1:"))
      separated = [] of String
      lines.each do |line|
        separated << line
        separated << APT_FETCH_SECURE_REPO_PREPEND if apt_fetch_reason_refused_repo?(line)
      end
      separated.pop if separated.last? == APT_FETCH_SECURE_REPO_PREPEND
      separated.join(", ")
    end

    # The two untrusted-repo notices apt pushes right after every refused
    # repo's "E: The repository ..." error (MessageInsecureRepository),
    # re-quoted at the front of the NEXT update's exception text whenever
    # they were trimmed off the previous text's tail (see
    # apt_fetch_failure_reason / apt_fetch_reason_trailing_refusal?).
    # Emitted in python-apt's own marker form (no space after "W:").
    APT_FETCH_SECURE_REPO_PREPEND = "W:Updating from such a repository can't be done securely, and is therefore disabled by default., W:See apt-secure(8) manpage for repository creation and user configuration details."

    # One failed attempt's reason bookkeeping, shared by the apt and
    # apt_repository update-cache retry loops: returns the attempt's
    # warning/final-msg text paired with whether IT leaves an unspent
    # untrusted-repo pair at its tail for the NEXT attempt (see
    # apt_fetch_reason_trailing_refusal?). The prepend decision uses the
    # PREVIOUS attempt's trailing state - the very first failed attempt's
    # text is quoted bare (verified against ansible-core 2.19.11: attempt
    # 1's warn carries only the GPG/E: lines, the two untrusted-repo lines
    # appear from attempt 2 on). Encapsulated here so both loops
    # structurally cannot compose the text from the CURRENT attempt's own
    # state - the apt_repository loop used to do exactly that and warned
    # with the prepend from its very first failure.
    #
    # The pair turns up only where a repo was REFUSED. The tolerated
    # failure shapes never get one - a [trusted=yes] repo's standalone
    # "W: GPG error ... NO_PUBKEY ..." warning, the allow-insecure "W:
    # ... potentially dangerous" lines, and plain index 404s keep the
    # identical unprefixed reason on every attempt (all live-verified
    # in-process, jammy 22.04 apt 2.4.14). That tolerated shape is
    # exactly issue #665's real round (xe0nic.ansible_vprotect_server):
    # both of the role's repos are `deb [trusted=yes]`, so real ansible
    # warned with the same unprefixed mixed GPG-warning + 404 text five
    # times and failed with it unprefixed, while the previous flag
    # trigger (any non-empty reason) prefixed the later attempts and the
    # final msg. The pair placement is in-process state: a separate
    # `apt-get update` CLI process never prints the pair (live-verified,
    # three consecutive CLI runs), so the placement stays a synthesis and
    # stays CLI-safe. The reason text arrives marker-space-stripped from
    # apt_fetch_failure_reason ("E: The" -> "E:The"), which is why the
    # probes have no space.
    def apt_fetch_reason_refused_repo?(reason : String) : Bool
      # An InRelease that fetched but is not a valid clearsigned file
      # ("E:Failed to fetch .../InRelease  Clearsigned file isn't valid,
      # got 'NOSPLIT'", e.g. an HTML login/error page served in its place)
      # never marks the repo untrusted even though the "is not signed" E:
      # line follows: real ansible quotes it bare on all five attempts and
      # in the final msg (issue #712, hax0rbana_adam.apt_repo).
      return false if reason.includes?("Clearsigned file isn't valid")
      reason.includes?("E:The repository '")
    end

    # Whether the text ENDS on a refusal line - i.e. that refusal's two
    # untrusted-repo notices were trimmed off the tail (see
    # apt_fetch_failure_reason) and surface at the front of the NEXT
    # in-process update's exception text instead. Probed live on noble
    # and trixie: a single missing-Release repo quotes just "E:..." on the
    # first update and "W:Updating..., W:See..., E:..." on every later
    # one, while round 29903261's marauderxtreme.local_system - whose text
    # ends on git-core's keyring warning instead - quoted the identical
    # text on all five attempts, no front pair ever. The clearsigned
    # shape (issue #712) pushes no notices at all and stays bare on every
    # attempt, hence the apt_fetch_reason_refused_repo? gate.
    def apt_fetch_reason_trailing_refusal?(reason : String) : Bool
      return false unless apt_fetch_reason_refused_repo?(reason)
      reason.matches?(/E:The repository '[^']*' [^.]*\.\z/)
    end

    # See the bookkeeping comment above apt_fetch_reason_refused_repo?:
    # prev_trailing_refusal is the PREVIOUS attempt's
    # apt_fetch_reason_trailing_refusal?, and the returned flag is this
    # attempt's own.
    def apt_fetch_attempt_reason(reason : String, prev_trailing_refusal : Bool) : {String, Bool}
      last_reason = prev_trailing_refusal && !reason.empty? ? "#{APT_FETCH_SECURE_REPO_PREPEND}, #{reason}" : reason
      {last_reason, apt_fetch_reason_trailing_refusal?(reason)}
    end

    # apt.py's FetchFailedException retry loop verbatim: `for retry in
    # range(update_cache_retries)` around cache.update(), exponential
    # backoff (2**retry plus a random sub-second jitter, capped at
    # update_cache_retry_max_delay plus jitter), one warn pair per failed
    # attempt (the fail warn before the sleep, the sleeping warn after
    # it). python-apt raises FetchFailedException() BARE - str() is the
    # empty string - so both the warning's "due to <e>" and the final
    # msg's reason come out EMPTY (round 1100002's py capture: "due to ,
    # retrying" / "Failed to update apt cache after 5 retries: "); the
    # 'unknown reason' fallback in apt.py's msg only fires when no
    # attempt ever raised (update_cache_retries=0 leaves err == '').
    # The caller only enters here after an attempt already failed, so
    # iteration 0's "after 1 retries" warn refers to that attempt - and
    # quotes ITS exception text when the failure was the SystemError-
    # wrapped signature class (see apt_fetch_failure_reason). Each later
    # failed attempt warns with its own text, gaining the two
    # untrusted-repo lines at the front whenever the previous attempt's
    # text ended on a refusal and left its pair unspent
    # (APT_FETCH_SECURE_REPO_PREPEND).
    # Returns recovered: true as soon as an attempt succeeds, with the
    # warnings emitted so far (they persist in the registered result
    # exactly like module.warn() texts do in Ansible) and last_reason -
    # the final attempt's exception text, which apt.py's final msg
    # quotes ("Failed to update apt cache after N retries: <reason>",
    # empty for the bare-exception class).
    def apt_fetch_failed_update_retry(retries : Int32, retry_max_delay : Int32,
                                      exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)),
                                      initial_reason : String = "", initial_trailing_refusal : Bool = false,
                                      jitter : Float64 = rand(1000) / 1000.0)
      warnings = [] of String
      recovered = false
      trailing_refusal = initial_trailing_refusal
      last_reason = initial_reason
      warned_reason = initial_reason
      retries.times do |attempt|
        warnings << "Failed to update cache after #{attempt + 1} retries due to #{warned_reason}, retrying"
        # apt.py draws `randomize` once before its loop, so every attempt
        # shares the same fractional part (observed 2,3,5,9,13 in one run)
        delay = 2.0 ** attempt + jitter
        delay = retry_max_delay + jitter if delay > retry_max_delay
        retry_sleep(delay)
        # ansible formats the delay with int(round(delay)) (Python round,
        # ties-to-even: 1.7s -> "2"), NOT %i truncation
        warnings << "Sleeping for #{AptRepositoryCacheRetry.sleeping_seconds(delay)} seconds, before attempting to refresh the cache again"
        result = exec_remote.call("apt-get update")
        if result[:exit_code] == 0 && !apt_fetch_failed?(result)
          recovered = true
          break
        end
        reason = apt_fetch_failure_reason(result)
        last_reason, trailing_refusal = apt_fetch_attempt_reason(reason, trailing_refusal)
        warned_reason = last_reason
      end
      {recovered: recovered, warnings: warnings, last_reason: last_reason}
    end

    # Detects the CLI-observable signature of a genuinely corrupt/
    # unparseable on-disk package index - NOT a plain "package doesn't
    # exist in an otherwise-valid cache" miss.
    #
    # Ansible's apt module (python-apt-backed) only retries when
    # `apt.Cache()` itself raises a `SystemError` whose message mentions
    # `/var/lib/apt/lists/` (`get_cache()` in ansible's `apt.py`) - that
    # is specifically a cache *open/parse* failure (corrupt or
    # unreadable index files), not "no candidate for this name". A
    # simple locate-miss on a valid-but-empty or valid-but-outdated
    # cache does NOT trigger it: `package_status()` fails straight to
    # `fail_json("No package matching '%s' is available")` with no
    # retry at all - confirmed live (0.9.737) against a genuinely empty
    # `/var/lib/apt/lists/`, where ansible-playbook failed outright
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

    # Same mtime probe Ansible's `get_cache_mtime()`/
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
    # interpreters Ansible's apt module probes
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

    # Emulates Ansible's apt module module-start auto-install of the
    # python3-apt bindings (apt.py's probe_interpreters_for_module +
    # "Updating cache and auto-installing missing dependency" path): a
    # real, PERSISTENT host mutation that changes every later apt
    # invocation's changed-reporting path. When the bindings are missing
    # this runs the same `apt-get update` prefetch (skipped only when the
    # task explicitly passed update_cache: false, per apt.py's own
    # `if module.params.get('update_cache') is False` guard), then
    # `apt-get install -y python3-apt`, exactly the two commands
    # Ansible runs before respawning itself. Returns nil when the
    # bindings were already present (a no-op) or the install succeeded;
    # returns the failed stage's raw command result plus its reported cmd
    # string when either command failed, mirroring Ansible's check_rc=True
    # hard failure.
    #
    # This engine previously only emulated the FIRST invocation's
    # observable `changed` behavior (the round-30001 rule) without ever
    # performing the install, so a host that started without the
    # bindings stayed on the "absent → changed=false" cache-refresh path
    # forever, while Ansible moved to the mtime-diff path after its
    # very first apt task. Found via geerlingguy.kubernetes (rounds
    # 65166/65311): the role's "Ensure dependencies are installed." task
    # triggers Ansible's auto-install, so its later "Update Apt
    # cache." task (immediately after deb822_repository added the
    # pkgs.k8s.io repo, whose freshly-fetched indexes genuinely move the
    # lists mtime) reported changed=true there, while this engine stayed
    # on the absent path and reported ok.
    #
    # `force_absent` is a spec seam only (never set by real playbooks): it
    # short-circuits the live probe so a spec running on a dev box that really
    # has the bindings can still drive the absent path through the plugin's
    # own call site.
    #
    # A failed stage returns the raw command result PLUS the cmd string
    # Ansible's own fail_json carries for that stage (issue #522): apt.py
    # resolves apt-get via module.get_bin_path(..., required=True), so the
    # reported cmd is the absolute /usr/bin/apt-get path even though this
    # engine executes the bare name through PATH - the reported string only,
    # what actually runs on the host is unchanged.
    def apt_auto_install_python_apt(skip_prefetch : Bool,
                                    exec_remote : Proc(String, AptLockRetry::AptCmdResult),
                                    force_absent : Bool = false) : NamedTuple(result: AptLockRetry::AptCmdResult, cmd: String)?
      return nil if !force_absent && apt_python_apt_present?(exec_remote)

      unless skip_prefetch
        result = exec_remote.call("apt-get update")
        return {result: result, cmd: APT_AUTO_INSTALL_UPDATE_CMD} if result[:exit_code] != 0
      end

      result = exec_remote.call("apt-get install -y python3-apt")
      return {result: result, cmd: APT_AUTO_INSTALL_INSTALL_CMD} if result[:exit_code] != 0
      nil
    end

    # Raw command-result shape every exec_remote in this module speaks.
    alias AptCmdResult = NamedTuple(exit_code: Int32, stdout: String, stderr: String)

    # The two reported cmd strings above (apt.py resolves the absolute
    # /usr/bin/apt-get path for its fail_json, this engine runs the bare
    # name through PATH), plus the warning apt.py emits BEFORE attempting
    # the auto-install - module.warn("Updating cache and auto-installing
    # missing dependency: python3-apt") - which shows up as the final
    # "[WARNING]: ..." line after the PLAY RECAP when a stage fails.
    APT_AUTO_INSTALL_UPDATE_CMD     = "/usr/bin/apt-get update"
    APT_AUTO_INSTALL_INSTALL_CMD    = "/usr/bin/apt-get install --no-install-recommends python3-apt -y -q"
    PYTHON_APT_AUTO_INSTALL_WARNING = "Updating cache and auto-installing missing dependency: python3-apt"

    # Builds the PluginResult a failed auto-install stage reports, shared by
    # apt.cr's and package.cr's three call sites so the shape can't drift.
    # Shaped like Ansible's own fail_json for a check_rc=True run_command
    # failure (issue #522, observed on the update stage): msg is the stderr with its
    # trailing newline stripped - NO "Failed to auto-install" prefix - the
    # keys dump in fail_json's sorted order, and there is NO cache_updated
    # key (the module never got to touch the cache). The result.extra
    # warnings carry the module's pre-failure warning so the final
    # "[WARNING]: Updating cache and auto-installing missing dependency:
    # python3-apt" line renders like real ansible's.
    def apt_auto_install_failure_result(failure : NamedTuple(result: AptLockRetry::AptCmdResult, cmd: String)) : PluginResult
      result = PluginResult.new(
        changed: false,
        failed: true,
        msg: failure[:result][:stderr].rstrip,
        cmd: failure[:cmd],
        rc: failure[:result][:exit_code],
        stdout: failure[:result][:stdout],
        stderr: failure[:result][:stderr],
        stdout_lines: failure[:result][:stdout].lines,
        stderr_lines: failure[:result][:stderr].lines,
        key_order: ["changed", "cmd", "msg", "rc", "stderr", "stderr_lines", "stdout", "stdout_lines"]
      )
      result.extra["warnings"] = JSON.parse([PYTHON_APT_AUTO_INSTALL_WARNING].to_json)
      result
    end

    # Ansible's apt module cannot run at all in check mode when it
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

    # Ansible's `changed` semantics for a cache-refresh-ONLY apt
    # invocation (no name:/upgrade:/deb: alongside it): WITHOUT
    # python3-apt, Ansible auto-installs it before its own
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
    # hardcoded `changed: true` for apt unconditionally, Ansible's
    # `ok`/`changed: false` on an already-fresh mirror).
    def apt_cache_refresh_changed?(pre_mtime : Int32, post_mtime : Int32,
                                   exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      return false unless apt_python_apt_present?(exec_remote)
      post_mtime != pre_mtime
    end

    # Ansible's apt module silently recovers from an install
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

    # Ansible's apt.py main() runs the cache refresh BEFORE any
    # install/remove/upgrade whenever `update_cache:` is set (or any
    # `cache_valid_time:` is) - unconditionally with the default
    # cache_valid_time: 0 (only the stamp-mtime + cache_valid_time < now
    # staleness gate can skip it), and even when every requested package
    # is already installed. Returns nil when no refresh is needed
    # (check mode - apt.py's own `if not module.check_mode: cache.update()`
    # guard skips it; no relevant params; still-fresh cache), else runs
    # `apt-get update` through `apt_get_update_with_retry` with
    # Ansible's update_cache_retries/update_cache_retry_max_delay
    # semantics, returning the failed result so the caller can fail the
    # task BEFORE touching any package state.
    def apt_update_cache_before_operation(update_cache : Bool, cache_valid_time : Int32,
                                          update_cache_retries : Int32, update_cache_retry_max_delay : Int32,
                                          check_mode : Bool,
                                          exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      return nil if check_mode
      return nil unless update_cache || cache_valid_time > 0
      return nil unless apt_cache_stale?(cache_valid_time, exec_remote)

      result = apt_get_update_with_retry("apt-get update", update_cache_retries, update_cache_retry_max_delay, exec_remote)
      return result if result[:exit_code] != 0

      nil
    end

    # Same freshness gate apt.cr's own should_update_cache? implements
    # (see there for the full real-Ansible apt.py rationale): with the
    # default cache_valid_time: 0 the refresh always runs; with a
    # positive cache_valid_time it only runs when the update-success-
    # stamp/lists-dir mtime is older than the validity window.
    def apt_cache_stale?(cache_valid_time : Int32,
                         exec_remote : Proc(String, NamedTuple(exit_code: Int32, stdout: String, stderr: String)))
      return true if cache_valid_time == 0

      age = Time.utc.to_unix - apt_cache_mtime(exec_remote)
      age > cache_valid_time
    end
  end
end

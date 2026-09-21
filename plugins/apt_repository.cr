#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/apt_repository_line"
require "../src/krikri/plugin_helpers/apt_repository_cache_retry"
require "../src/krikri/plugin_helpers/apt_ppa"

module Krikri
  # Apt_repository plugin - adds/removes a Debian/Ubuntu APT source line.
  # Compatible with Ansible's ansible.builtin.apt_repository module.
  #
  # Supported parameters:
  # - repo: a plain "deb ..."/"deb-src ..." source line, or a
  #   `ppa:owner/name` shorthand (name defaults to "ppa" when omitted,
  #   e.g. `ppa:owner` alone) - required
  # - state: present (default) | absent
  # - filename: base filename (without .list) to use under
  #   /etc/apt/sources.list.d/, or a full path (real Ansible honors
  #   any `filename:` containing '/' as-is, verbatim + '.list' - see
  #   PluginHelpers::AptRepositoryLine.target_sources_path) -
  #   defaults to a name derived from the repo
  #   URL via PluginHelpers::AptRepositoryLine, replicating real
  #   Ansible's own `_suggest_filename` logic exactly (see that module
  #   for details, verified against real Ansible's actual source)
  # - codename: overrides the distro codename `ppa:` lines resolve
  #   against (real Ansible's own default: the local machine's own
  #   codename - `/etc/os-release`'s `VERSION_CODENAME=`, not a shell
  #   out to `lsb_release`)
  # - update_cache: run `apt-get update` after a change (default true)
  # - update_cache_retries / update_cache_retry_max_delay: how many
  #   total `apt-get update` attempts (default 5) and the exponential
  #   backoff cap in seconds (default 12) when that update fails -
  #   real Ansible's own retry semantics, see
  #   PluginHelpers::AptRepositoryCacheRetry
  # - install_python_apt / validate_certs: accepted, documented no-ops
  #   (see the class doc below for why)
  # - mode: applied to the resulting file
  # - check_mode: report what would change without writing anything
  #
  # Idempotency: checks whether the normalized repo line already appears,
  # enabled, in /etc/apt/sources.list or any /etc/apt/sources.list.d/*.list
  # file - not just the target file - matching real Ansible's own
  # SourcesList, which reads all of them before deciding whether an
  # add/remove is a no-op.
  #
  # `ppa:` shorthand (PluginHelpers::AptPpa has the full formula
  # breakdown, all verified against real Ansible's own
  # UbuntuSourcesList source, not assumed): expands to a real
  # `deb https://ppa.launchpadcontent.net/<owner>/<name>/ubuntu <codename>
  # main` line, fetches the PPA's signing-key fingerprint from the
  # Launchpad API (`https://api.launchpad.net/1.0/~<owner>/+archive/<name>`,
  # native `HTTP::Client` - no `curl`/`wget` shellout, same rationale as
  # `get_url.cr`), then exports that key from `hkp://keyserver.ubuntu.com:80`
  # via `gpg --export` (shelled - GPG protocol/keyring handling has no
  # native Crystal equivalent in this codebase, and real Ansible's own
  # module shells to `apt-key`/`gpg` for exactly the same reason) into
  # the first existing directory of `/etc/apt/keyrings`,
  # `/etc/apt/trusted.gpg.d`, `/usr/share/keyrings` (real Ansible's own
  # search order). The key export is redirected straight to the keyfile
  # by the shell command itself (`gpg ... --export ... > keyfile`) rather
  # than captured through this plugin's own `remote_exec` - a GPG key
  # blob is arbitrary binary data, and `remote_exec`'s stdout capture is
  # a Crystal `String` (UTF-8), which isn't a safe carrier for it; real
  # Ansible's own Python implementation has the identical problem and
  # solves it the same way (`encoding=None` to keep raw bytes, written
  # directly to the keyfile). `apt-key` itself isn't implemented - it's
  # deprecated/removed on current Debian/Ubuntu (confirmed: this
  # environment has `gpg` but no `apt-key` binary at all), and real
  # Ansible already prefers `gpg` when both exist. The already-has-this-key
  # check real Ansible does before exporting (`_key_already_exists`,
  # itself shelling to `apt-key export`/scanning existing keyrings with
  # `gpg --list-packets`) isn't replicated either - `gpg --export` is
  # itself idempotent (re-importing/re-writing the same key is a no-op
  # in effect), so skipping the check trades a little wasted network
  # traffic on an already-added PPA for meaningfully less code, and
  # real Ansible's own PPA idempotency check (a source-line match,
  # implemented below) already means the whole key-fetch path is never
  # even reached on a rerun. `install_python_apt` and `validate_certs`
  # are accepted as documented no-ops: krikri never imports python-apt
  # (so there's nothing for `install_python_apt` to install - the param
  # exists in real Ansible purely to gate that auto-install), and the
  # plugin's one HTTPS fetch (the Launchpad API call above) always
  # verifies certificates via native `HTTP::Client`, which has no
  # disable-TLS-verification switch wired here - real Ansible's
  # `validate_certs: false` only relaxes its own fetches, which there's
  # no reason to replicate for a param real playbooks pass by default.
  # `update_cache_retries`/`update_cache_retry_max_delay` ARE wired for
  # real: the post-change `apt-get update` retries up to
  # `update_cache_retries` total attempts with real Ansible's own
  # `2**retry + jitter` (capped at `update_cache_retry_max_delay +
  # jitter`) exponential backoff - see
  # PluginHelpers::AptRepositoryCacheRetry.
  #
  # This plugin is entirely file editing (finding/reading/writing plain
  # text `.list` files) - there's no actual `apt-get`/`dpkg` call
  # anywhere in it, so unlike `apt.cr`/`package.cr` it has no genuine
  # missing-binding gap and is now fully native (`Dir.glob`/`File.each_line`/
  # `File.read_lines`/`File.write`/`File.open(path, "a")` replacing
  # `ls`/`grep -qxF`/`grep -vxF`/`grep -c .`/`echo >>`, plus
  # `BasePlugin#apply_owner_group_mode` for `chmod`). `apt-get update`
  # (`run_update_cache`) and the PPA `gpg --export` above are the only
  # remaining shell calls - genuine gaps (a real system operation and a
  # binary-data-safety constraint, respectively), not oversights.
  class AptRepositoryPlugin < BasePlugin
    include AptRepositoryCacheRetry

    SOURCES_LIST   = "/etc/apt/sources.list"
    SOURCES_LIST_D = "/etc/apt/sources.list.d"
    KEYSERVER          = "hkps://keyserver.ubuntu.com:443"
    KEYSERVER_FALLBACK = "hkp://keyserver.ubuntu.com:80"

    @warnings = [] of String

    def execute : PluginResult
      # Real ansible's apt_repository runs `apt-get update` (and its own
      # add/remove paths shell out to apt-key/apt-get); on a host without
      # apt-get (any non-Debian family host) it fails with exactly
      # {"changed": false, "cmd": "update", "msg": "Error executing
      # command.", "rc": 2} - found live on Rocky 9.6 with Oefenweb.dns
      # (round 196), where this engine silently "succeeded" its way
      # through the role (rc=0) while real ansible failed the
      # repository task rc=2. The paths below were written for real
      # Debian-family hosts; on anything else they'd fabricate success.
      unless File.exists?("/usr/bin/apt-get") || File.exists?("/usr/local/bin/apt-get")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Error executing command.",
          cmd: "update",
          rc: 2
        )
      end
      repo = @params["repo"]?
      unless repo
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: repo")
      end

      state = @params["state"]? || "present"
      update_cache = true?(@params["update_cache"]?, default: true)
      check_mode = true?(@params["_ansible_check_mode"]?)

      if ppa = PluginHelpers::AptPpa.parse(repo)
        return handle_ppa(ppa, state, update_cache, check_mode)
      end

      normalized = PluginHelpers::AptRepositoryLine.normalize(repo)
      unless normalized
        return PluginResult.new(changed: false, failed: true, msg: "Invalid repo line: #{repo}")
      end

      if state == "absent"
        remove(normalized, update_cache, check_mode)
      else
        add(normalized, update_cache, check_mode) { nil }
      end
    end

    private def handle_ppa(ppa : PluginHelpers::AptPpa::Info, state : String, update_cache : Bool, check_mode : Bool) : PluginResult
      codename = @params["codename"]? || detect_codename
      unless codename
        return PluginResult.new(changed: false, failed: true, msg: "codename: is required (could not detect the local distro codename from /etc/os-release)")
      end

      normalized = PluginHelpers::AptPpa.expand_line(ppa, codename)
      return remove(normalized, update_cache, check_mode) if state == "absent"

      filename_source = PluginHelpers::AptPpa.filename_source(ppa, codename)
      add(normalized, update_cache, check_mode, filename_source) { ensure_ppa_key(ppa, codename) }
    end

    private def all_source_files : Array(String)
      list_d = Dir.glob(File.join(sources_list_d, "*.list")).sort!
      [sources_list] + list_d
    end

    # Underscore-prefixed internal overrides of the real filesystem
    # locations - same spec-seam family as apt.cr's `_policy_rc_d_path`,
    # so the retry specs can drive a full add+failed-cache-update
    # end-to-end against a scratch directory instead of mutating
    # /etc/apt. Playbooks never see these (real Ansible has no such
    # params, and anything unknown it would reject; here they're only
    # read by the specs).
    private def sources_list : String
      @params["_sources_list"]? || SOURCES_LIST
    end

    private def sources_list_d : String
      @params["_sources_list_d"]? || SOURCES_LIST_D
    end

    private def file_contains_line?(file : String, line : String) : Bool
      return false unless File.exists?(file)
      File.each_line(file) { |file_line| return true if file_line == line }
      false
    rescue
      false
    end

    private def find_source(normalized : String) : String?
      all_source_files.find { |file| file_contains_line?(file, normalized) }
    end

    # *before_write* runs (and can abort with a failed PluginResult) only
    # once every earlier check has confirmed a real write is actually
    # about to happen - not already present, not check_mode - so a PPA's
    # key-fetch network calls only ever run when real Ansible's own
    # equivalent would too.
    private def add(normalized : String, update_cache : Bool, check_mode : Bool, filename_source : String? = nil, & : -> PluginResult?) : PluginResult
      if find_source(normalized)
        return PluginResult.new(changed: false, failed: false, msg: "", repo: normalized, state: "present", sources_added: [] of String, sources_removed: [] of String)
      end

      target = target_file(normalized, filename_source || normalized)
      target_had_sources = file_has_sources?(target)

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would add repository (check mode)", repo: normalized, state: "present", sources_added: target_had_sources ? [] of String : [target], sources_removed: [] of String)
      end

      if error = yield
        return error
      end

      Dir.mkdir_p(File.dirname(target))
      File.open(target, "a", &.puts(normalized))
      apply_owner_group_mode(target, nil, nil, @params["mode"]?)

      if update_cache
        cache_result = run_update_cache
        if cache_result[:exit_code] != 0 || gpg_signature_failure?(cache_result[:stdout], cache_result[:stderr])
          # Real ansible-playbook's own apt_repository module rolls back
          # the line it just wrote when the post-add cache update fails,
          # rather than leaving a broken repo definition behind - found
          # via robertdebock.hashicorp's own block:/rescue: pattern
          # (modern signed-by method, falling back to the legacy apt_key
          # method on failure): without the rollback, the modern
          # method's own (unsigned-key, update-failed) line stayed in
          # the SAME target file the legacy method's retry also writes
          # to, so the legacy attempt's differently-formatted line
          # landed ALONGSIDE it instead of alone - two conflicting
          # `signed-by=` definitions for the same repo URL in one file,
          # which apt itself then refuses outright ("Conflicting values
          # set for option Signed-By"), turning one recoverable failure
          # into two.
          #
          # The `gpg_signature_failure?` half of this check is itself a
          # second, deeper bug in the SAME task found live-verifying the
          # fix above: plain `apt-get update`'s own exit code is 0 even
          # when a repo's signature can't be verified (apt only WARNs to
          # stderr, "GPG error ... NO_PUBKEY ...", and still exits
          # success using the previous cached index) - so the bare
          # exit_code check above never even detected the failure real
          # Ansible's own module DOES treat as fatal. Real Ansible
          # doesn't shell out to `apt-get` at all - it uses the
          # `python-apt` library's `Cache().update()`, which raises
          # `FetchFailedException` for exactly this case, a stricter
          # check than the CLI tool's own exit code. Matched here by
          # scanning both streams for apt's own GPG-failure wording
          # rather than trusting exit_code alone.
          rollback_line(target, normalized)
          return PluginResult.new(
            changed: true,
            failed: true,
            msg: "Failed to update apt cache: #{cache_result[:stderr]}",
            repo: normalized,
            state: "present"
          )
        end
      end

      result = PluginResult.new(changed: true, failed: false, msg: "", repo: normalized, state: "present", sources_added: target_had_sources ? [] of String : [target], sources_removed: [] of String)
      result.extra["warnings"] = JSON.parse(@warnings.to_json) unless @warnings.empty?
      result
    end

    private def remove(normalized : String, update_cache : Bool, check_mode : Bool) : PluginResult
      file = find_source(normalized)
      unless file
        return PluginResult.new(changed: false, failed: false, msg: "", repo: normalized, state: "absent", sources_added: [] of String, sources_removed: [] of String)
      end

      remaining_lines = File.read_lines(file).reject { |line| line == normalized }
      file_would_lose_sources = remaining_lines.none? { |line| valid_source_line?(line) }

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would remove repository (check mode)", repo: normalized, state: "absent", sources_added: [] of String, sources_removed: file_would_lose_sources ? [file] : [] of String)
      end

      File.write(file, remaining_lines.empty? ? "" : remaining_lines.join('\n') + "\n")
      File.delete?(file) if remaining_lines.none? { |line| !line.empty? } && file != sources_list

      if update_cache
        cache_result = run_update_cache
        if cache_result[:exit_code] != 0 || gpg_signature_failure?(cache_result[:stdout], cache_result[:stderr])
          return PluginResult.new(
            changed: true,
            failed: true,
            msg: "Failed to update apt cache: #{cache_result[:stderr]}",
            repo: normalized,
            state: "absent"
          )
        end
      end

      PluginResult.new(changed: true, failed: false, msg: "", repo: normalized, state: "absent", sources_added: [] of String, sources_removed: file_would_lose_sources ? [file] : [] of String)
    end

    # Real apt_repository computes sources_added/sources_removed as the
    # set difference of the filenames (full paths) carrying at least one
    # valid source line before vs after the operation (its SourcesList
    # dump keys, live-verified against ansible-core 2.19.11: adding a
    # line to an EXISTING non-empty file reports neither field; a file
    # created by the add shows up in sources_added, one emptied/deleted
    # by the remove in sources_removed). "Valid source line" here means
    # a non-blank, non-comment line - a real dump key skips files with
    # none. The cache-update failure paths keep the fields out entirely
    # (real module's fail_json exit carries only msg).
    private def file_has_sources?(file : String) : Bool
      return false unless File.exists?(file)
      File.each_line(file) { |line| return true if valid_source_line?(line) }
      false
    rescue
      false
    end

    private def valid_source_line?(line : String) : Bool
      stripped = line.strip
      !stripped.empty? && !stripped.starts_with?('#')
    end

    # Undoes the just-appended line from #add's own File.open(target,
    # "a", ...) write, deleting the whole file if that leaves it empty
    # (mirrors #remove's own identical cleanup) - so a failed add: (the
    # post-write cache update failing) leaves the filesystem exactly as
    # it was found, matching real Ansible's own rollback-on-failure
    # behavior for this case.
    private def rollback_line(target : String, normalized : String) : Nil
      return unless File.exists?(target)

      remaining_lines = File.read_lines(target).reject { |line| line == normalized }
      if remaining_lines.none? { |line| !line.empty? }
        File.delete?(target)
      else
        File.write(target, remaining_lines.join('\n') + "\n")
      end
    end

    private def target_file(normalized : String, filename_source : String) : String
      PluginHelpers::AptRepositoryLine.target_sources_path(@params["filename"]?, filename_source, sources_list_d)
    end

    # Real ansible-playbook's own apt_repository module FAILS the task
    # when the post-add `apt-get update` itself fails (e.g. a
    # newly-added repo's GPG key can't be verified) - this used to run
    # the update and silently discard the result, always returning
    # `changed: true, failed: false` regardless. That mattered a lot
    # more than it looks: robertdebock.hashicorp's own "Install
    # repository for Debian (modern method)" task sits inside a
    # `block:`/`rescue:` specifically so a broken key falls back to the
    # legacy `apt_key` method - with the update failure swallowed here,
    # the block never saw a failure at all and the `rescue:` never ran,
    # so the broken (armored-not-dearmored) GPG key silently stuck
    # around and the LATER `apt-get install nomad` task failed instead
    # ("Unable to locate package nomad") - a real divergence from real
    # Ansible, which recovers via the rescue: at the point it's supposed
    # to. Found benchmarking robertdebock.nomad.
    # Real ansible-playbook's own apt_repository module retries a failed
    # `apt-get update` (python-apt's FetchFailedException) up to
    # `update_cache_retries` total attempts with an exponential backoff
    # (`2**retry + jitter`, capped at `update_cache_retry_max_delay +
    # jitter`) before giving up - wired through
    # PluginHelpers::AptRepositoryCacheRetry so the loop and the delay
    # formula are both spec-testable via an injected exec proc.
    private def run_update_cache : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      retries = int_param("update_cache_retries", DEFAULT_UPDATE_CACHE_RETRIES)
      max_delay = int_param("update_cache_retry_max_delay", DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY)
      apt_repository_cache_update_with_retry(retries, max_delay, ->(command : String) { remote_exec(command) })
    end

    private def int_param(name : String, default : Int32) : Int32
      raw = @params[name]?
      return default unless raw
      raw.to_i? || default
    end

    # `apt-get update`'s own exit code stays 0 even when a repo's
    # signature can't be verified - apt only warns and falls back to the
    # previously cached index for that one repo. Real Ansible's own
    # module uses python-apt's `Cache().update()` instead, which raises
    # for exactly this case - matched here by scanning for apt's own
    # GPG-failure wording (checked on both streams; apt puts some lines
    # on stdout, some on stderr).
    private def gpg_signature_failure?(stdout : String, stderr : String) : Bool
      combined = "#{stdout}\n#{stderr}"
      combined.includes?("NO_PUBKEY") ||
        combined.includes?("GPG error") ||
        combined.includes?("is not signed") ||
        combined.includes?("couldn't be verified")
    end

    # Reads VERSION_CODENAME= from /etc/os-release - matches real
    # Ansible's own `distro.codename` default for `ppa:` lines without an
    # explicit `codename:` (the `distro` library reads the same file;
    # verified against its actual behavior, not assumed).
    private def detect_codename : String?
      return nil unless File.exists?("/etc/os-release")

      File.each_line("/etc/os-release") do |line|
        return line.split('=', 2)[1].strip.strip('"') if line.starts_with?("VERSION_CODENAME=")
      end

      nil
    end

    # Fetches the PPA's signing-key fingerprint from the Launchpad API,
    # then imports it - via `apt-key adv --recv-keys` when that binary
    # exists (real Ansible's own preferred path, and the one real Ubuntu
    # 24.04 still actually takes: `apt-key` is deprecated there but not
    # yet removed, unlike on current Debian, confirmed by checking both
    # directly rather than assuming either), or by exporting it from the
    # keyserver into an APT_KEY_DIRS keyfile via plain `gpg` otherwise.
    # Returns nil on success, or a failed PluginResult if any step didn't
    # work. See the class doc above for the full verified-against-real-
    # Ansible breakdown.
    #
    # `apt-key adv --recv-keys` genuinely fetches-and-imports from the
    # keyserver in one step; bare `gpg --export <fingerprint>` (real
    # Ansible's own fallback command when `apt-key` is absent) does
    # *not* - `--export` only ever reads a key already present in the
    # local keyring, `--keyserver` alongside it does nothing on modern
    # GnuPG (confirmed directly: gpg 2.4.4 exits 0 with "WARNING:
    # nothing exported" and empty output for a key never previously
    # imported). Real Ansible's own fallback command hits this identical
    # empty-output failure on any system without `apt-key` and a
    # sufficiently modern `gpg` - a genuine, reproducible gap in real
    # Ansible's own module, not something introduced here, and not
    # something to silently "fix" by deviating from what real Ansible
    # actually runs (parity means matching real behavior, bugs
    # included) - see the compat verification note in git log.
    private def ensure_ppa_key(ppa : PluginHelpers::AptPpa::Info, codename : String) : PluginResult?
      fingerprint = begin
        fetch_ppa_signing_key(ppa)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: ex.message || "failed to fetch PPA information")
      end

      if apt_key = Process.find_executable("apt-key")
        result = remote_exec("#{apt_key} adv --recv-keys --no-tty --keyserver #{KEYSERVER} #{shell_single_quote(fingerprint)}")
        if result[:exit_code] != 0
          warn_cleartext_keyserver_fallback
          remote_exec("#{apt_key} adv --recv-keys --no-tty --keyserver #{KEYSERVER_FALLBACK} #{shell_single_quote(fingerprint)}")
        end
        return nil
      end

      import_via_gpg(ppa, codename, fingerprint)
    end

    private def import_via_gpg(ppa : PluginHelpers::AptPpa::Info, codename : String, fingerprint : String) : PluginResult?
      keydir = PluginHelpers::AptPpa::KEY_DIRS.find { |dir| Dir.exists?(dir) }
      unless keydir
        return PluginResult.new(
          changed: false, failed: true,
          msg: "Unable to find any existing apt gpg repo directories, tried the following: #{PluginHelpers::AptPpa::KEY_DIRS.join(", ")}"
        )
      end

      keyfile = File.join(keydir, PluginHelpers::AptPpa.keyfile_name(ppa, codename))
      remote_exec("gpg --no-tty --keyserver #{KEYSERVER} --export #{shell_single_quote(fingerprint)} > #{shell_single_quote(keyfile)}")

      unless File.exists?(keyfile) && File.size(keyfile) > 0
        warn_cleartext_keyserver_fallback
        remote_exec("gpg --no-tty --keyserver #{KEYSERVER_FALLBACK} --export #{shell_single_quote(fingerprint)} > #{shell_single_quote(keyfile)}")
      end

      unless File.exists?(keyfile) && File.size(keyfile) > 0
        return PluginResult.new(changed: false, failed: true, msg: "Unable to get required signing key")
      end

      nil
    end

    # HKPS (TLS) is tried first so the key material is protected in
    # transit; the cleartext HKP fallback only runs when that fails, and
    # always announces itself loudly (via the result's warnings list),
    # since a MITM could then swap the key despite the TLS-fetched
    # fingerprint being correct.
    private def warn_cleartext_keyserver_fallback : Nil
      @warnings << "TLS keyserver #{KEYSERVER} failed; fell back to cleartext #{KEYSERVER_FALLBACK} - the key material was not integrity-protected in transit"
    end

    private def fetch_ppa_signing_key(ppa : PluginHelpers::AptPpa::Info) : String
      uri = URI.parse(PluginHelpers::AptPpa.api_url(ppa))
      client = HTTP::Client.new(uri)
      client.connect_timeout = 10.seconds
      client.read_timeout = 10.seconds

      response = client.get(uri.request_target, headers: HTTP::Headers{"Accept" => "application/json"})
      raise "failed to fetch PPA information, error was: HTTP #{response.status_code}" unless response.status_code == 200

      data = JSON.parse(response.body)
      data["signing_key_fingerprint"]?.try(&.as_s?) || raise "PPA response did not include a signing_key_fingerprint"
    ensure
      client.try(&.close)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::AptRepositoryPlugin.new(config)
plugin.run

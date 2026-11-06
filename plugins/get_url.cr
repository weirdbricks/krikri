#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "socket"
require "../src/krikri/base_plugin"
require "../src/krikri/python_literal"
require "../src/krikri/plugin_helpers/http_download"
require "../src/krikri/plugin_helpers/url_preflight"
require "../src/krikri/plugin_helpers/url_mask"

module Krikri
  # get_url plugin (ansible.builtin.get_url) - downloads a URL to a file.
  #
  # Uses Crystal stdlib HTTP::Client natively rather than shelling to
  # curl/wget. Unlike a plain "local vs remote" split elsewhere in this
  # codebase, no remote_exec branch is needed here at all: PluginManager
  # already uploads and executes this plugin's own compiled binary
  # directly on the target host for non-local connections (see
  # BasePlugin#native_stat's own comment on the same point), so an
  # HTTP::Client call made from inside this process already runs on
  # whichever host - local or remote - the task is targeting.
  class GetUrlPlugin < BasePlugin
    # ansible.builtin.get_url's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.get_url). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[backup decompress force force_basic_auth unsafe_writes use_gssapi use_netrc
        use_proxy validate_certs]
    end

    MAX_REDIRECTS = 10

    # Real get_url's serialized result key order (ansible-core 2.19.11,
    # verified both live - a registered result dumped via the to_json
    # filter - and in the module source: exit_json's msg/status_code
    # kwargs lead, then the module-level result dict
    # (changed, checksum_dest, checksum_src, dest, elapsed, url) in its
    # own insertion order plus the success-path src/md5sum additions,
    # then basic.py add_path_info's stat block). Keys krikri's result
    # doesn't carry on a given path (e.g. backup_file when no backup: was
    # requested) are simply skipped by the reorder; keys krikri emits that
    # Ansible doesn't would keep their current relative order at the end.
    private SUCCESS_KEY_ORDER = %w[msg status_code changed checksum_dest checksum_src dest elapsed url src md5sum backup_file uid gid owner group mode state size]

    # 2.21 masks the url: value it echoes back (module_utils/urls.py
    # mask_url()), so a user:password@host login stops showing up in task
    # output. Done once here rather than at the ~12 result sites.
    def execute : PluginResult
      result = build_result
      if (echoed = result.extra["url"]?.try(&.as_s?))
        result.extra["url"] = JSON::Any.new(PluginHelpers::UrlMask.mask(echoed))
      end
      result
    end

    private def build_result : PluginResult
      validate_bool_params!
      url = @params["url"]?
      dest = @params["dest"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: url") unless url
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: dest") unless dest

      # Real get_url types headers: as a dict, so a plain string goes through
      # Ansible's check_type_dict during arg-spec validation, before the module
      # body - and thus before every check below. A failed conversion kills the
      # task right there (live-verified vs 2.19.11, including the order: the
      # "unable to convert to dict" error only fires once url:/dest: are
      # present, since Ansible reports missing required arguments first).
      user_headers, headers_error = converted_headers
      if err = headers_error
        return PluginResult.new(changed: false, failed: true, msg: err)
      end

      # Real get_url strips surrounding whitespace (including newlines) off
      # the url before doing anything with it - urllib's Request rejects the
      # padded string with "unknown url type:    http" - while every result
      # still reports the raw, unstripped string in its url: field
      # (live-verified against ansible-core 2.19.11).
      request_url = url.strip

      dest = expand_tilde(dest)
      # Real get_url's own `dest` param, verbatim. Every failure result
      # Ansible reports names THIS path, including a directory dest (whose
      # filename is only derived once the request came back, so a failed
      # download of a directory dest reports the directory itself).
      dest_param = dest
      # Real get_url only derives the final filename AFTER the request
      # completes when dest: is a directory (get_url.py's dest_is_dir
      # block): first the final response's Content-Disposition filename,
      # else the basename of the FINAL post-redirect URL - the original
      # URL's path is never used. Deriving it up front from the original
      # URL misnamed every download behind a redirecting endpoint (round
      # 979121, mrlesmithjr.guacamole: its apache.org/dyn/closer.cgi?...
      # URL has path /dyn/closer.cgi, so the download landed at
      # <dir>/closer.cgi and the next task's unarchive failed with
      # "Source ... failed to transfer" while Ansible had the file
      # under the redirect target's own name).
      dest_is_dir = File.directory?(dest)
      # Pre-request filename guess, check-mode messaging only: in check
      # mode no request is made, so there's no final response to derive
      # from (Ansible HEADs the URL for this; we keep the guess).
      dest = File.join(dest, url_filename(request_url)) if dest_is_dir

      checksum = resolved_checksum(url, request_url, dest_param)
      return checksum if checksum.is_a?(PluginResult)

      force = true?(@params["force"]?, default: false)
      # Real get_url's conditional-GET state, decided here exactly where
      # get_url.py decides it (its `if not dest_is_dir and os.path.exists(dest)`
      # block): `last_mod_time` is dest's mtime and goes out as
      # If-Modified-Since when no checksum forced a full re-download, and a
      # checksum MISMATCH (which only reaches this block when it didn't match)
      # sets force=True for the re-download instead - Ansible's own reasoning:
      # "the checksum does not match ... last_mod_time may be newer than on
      # remote", so the fresh request carries cache-control: no-cache rather
      # than a stale If-Modified-Since.
      last_mod_time : Time? = nil
      if File.exists?(dest) && !force && !dest_is_dir
        if skip_result = check_existing_dest(dest, checksum)
          return skip_result
        end
        if checksum
          force = true
        else
          # Seconds precision, like Ansible's
          # datetime.fromtimestamp(mtime, timezone.utc).timetuple() feeding
          # rfc2822_date_string. A 304 answer short-circuits OK in Ansible's
          # url_get (msg = fetch_url's info['msg'], i.e. urllib's own
          # "HTTP Error 304: Not Modified"); a 200 falls through to the full
          # download + SHA1 compare below.
          last_mod_time = Time.unix(File.info(dest).modification_time.to_unix)
        end
        # Checksum given but doesn't match (or no checksum at all - see
        # check_existing_dest): fall through and re-download, regardless
        # of force - the checksum is its own freshness check, matching
        # Ansible's get_url behavior.
      end

      # Real get_url only reaches its request (get_url.py's url_get ->
      # fetch_url) once the above skipped, and fetch_url builds the SSL
      # context and resolves the gssapi handler BEFORE urllib parses the
      # URL - so a bad ciphers: list, an unusable client_cert:/client_key:
      # or use_gssapi: on a host without python-gssapi fails with THAT
      # error, and only a request that survives all of it can reach
      # urllib's scheme-less-URL ValueError. Live-verified both halves
      # against ansible-core 2.19.11: get_url with ciphers: [fdpfji,
      # ahatju] over a plain http:// URL fails with "Connection failure:
      # ('No cipher can be selected.',)" (no request is ever made), and a
      # dest that already matches its checksum: short-circuits with ok
      # even for a scheme-less URL that would have failed had it been
      # requested at all.
      if failure = PluginHelpers::URLPreflight.check(
           request_url,
           ciphers: tls_ciphers,
           client_cert: @params["client_cert"]?,
           client_key: @params["client_key"]?,
           use_gssapi: true?(@params["use_gssapi"]?, default: false),
         )
        return preflight_failure_result(failure, url, dest)
      end

      if bad = invalid_header_name(user_headers)
        return PluginResult.new(changed: false, failed: true, msg: "Invalid header name #{python_bytes_repr(python_title(bad))}", url: url, status: -1)
      end

      if true?(@params["_ansible_check_mode"]?)
        result = PluginResult.new(changed: true, failed: false, msg: "would download #{request_url} to #{dest} (check mode)", dest: dest, key_order: SUCCESS_KEY_ORDER)
        add_path_info(result, dest)
        return result
      end

      # tmp_dest is validated up front (real get_url's url_get does it
      # right before staging) so a bad tmp_dest fails before any request.
      if (tmp_dest_param = @params["tmp_dest"]?) && (tmp_error = staging_dir_error(tmp_dest_param))
        return tmp_error
      end

      download_to_dest(url, request_url, dest_param, checksum, dest_is_dir, force, last_mod_time)
    end

    # Parses the checksum: param (if any) into its {algorithm, hash}
    # tuple, or a failed PluginResult on resolution failure. An empty
    # checksum: string is Ansible's own signal for "no checksum
    # given" (its get_url module explicitly treats a falsy checksum the
    # same as an absent one), NOT a value to actually verify against -
    # found via juju4.openobserve's own `checksum: "{{ openobserve_hash |
    # default(omit) }}"` where openobserve_hash DEFAULTS to "" (a real,
    # DEFINED empty string, not undefined) for this OS/arch combination,
    # so default(omit) never fires for either engine - both receive
    # checksum: "" identically. Without this, krikri tried to verify the
    # real download against an empty expected hash and failed every
    # single time ("checksum mismatch: expected , got <real hash>")
    # where Ansible correctly skips verification.
    private def resolved_checksum(url : String, request_url : String, dest : String) : {String, String}? | PluginResult
      checksum_param = @params["checksum"]?
      return nil if checksum_param.nil? || checksum_param.strip.empty?

      # get_url.py: `algorithm, checksum = checksum.split(':', 1)` -> ValueError
      # -> fail_json(msg=..., **result) with the module's initial result dict
      unless checksum_param.includes?(':')
        return PluginResult.new(changed: false, failed: true,
          msg: "The checksum parameter has to be in format <algorithm>:<checksum>",
          checksum_dest: nil, checksum_src: nil,
          dest: expand_tilde(@params["dest"]? || ""), elapsed: 0, url: url)
      end

      begin
        parsed = parse_checksum(checksum_param, request_url, dest)
        return parsed if parsed.is_a?(PluginResult)
        parsed.as({String, String})
      rescue ex
        PluginResult.new(changed: false, failed: true, msg: "failed to resolve checksum: #{ex.message}", status_code: -1)
      end
    end

    # Returns a PluginResult if the download can be skipped (dest already
    # present and a given checksum matches), nil to signal "proceed with
    # download".
    #
    # With NO checksum given there is never a requestless skip here:
    # ansible-core's get_url always performs the HTTP request when dest
    # exists (a conditional GET keyed on dest's mtime - #execute sets
    # last_mod_time for it, and a 304 answer short-circuits in
    # not_modified_result), then decides changed by comparing the freshly
    # fetched content's SHA1 against the existing dest file's SHA1 - even
    # with no checksum: param at all. Found as round952314's buluma.fish
    # divergence: its "Add fish repository key" get_url task (no
    # checksum:, no force:, fetching the live keyserver.ubuntu.com
    # lookup) always short-circuited to ok on a warm rerun purely because
    # the dest file existed, without making any request, where
    # Ansible re-requested and - since a dynamic endpoint's response can
    # differ run to run - sometimes reported changed: true. Falling
    # through to download_to_dest's fetch + SHA1 compare reproduces the
    # same changed flag (and the conditional GET now reproduces Ansible's
    # 304 short-circuit too).
    #
    # File-common attribute reconciliation on the checksum-match skip
    # path mirrors Ansible's get_url exactly (live-read against
    # ansible-core 2.19.4's module source): set_fs_attributes_if_different
    # runs even when the download is skipped, and a stale attribute flips
    # the result to changed: true with msg "file already exists but file
    # attributes changed".
    private def check_existing_dest(dest : String, checksum : {String, String}?) : PluginResult?
      return nil unless checksum

      algorithm, expected = checksum
      return nil unless native_checksum(dest, algorithm) == expected

      attrs_changed = false
      unless true?(@params["_ansible_check_mode"]?)
        attrs_changed, failure = apply_extended_attributes(dest)
        return failure if failure
      end

      result = PluginResult.new(changed: attrs_changed || false, failed: false, msg: attrs_changed ? "file already exists but file attributes changed" : "file already exists", dest: dest, checksum_src: nil, checksum_dest: nil, key_order: SUCCESS_KEY_ORDER)
      add_path_info(result, dest)
      result
    end

    # Real get_url's three pre-request failures (see URLPreflight) reach
    # the task with three different result shapes, all live-verified
    # against ansible-core 2.19.11:
    #
    #   * MissingLibrary - fetch_url's `except MissingModuleError` handler
    #     is a bare fail_json(msg=...): {changed: false, msg}, with no
    #     url/dest/elapsed at all.
    #   * UnknownUrlType - the ValueError from urllib's Request(url),
    #     re-raised as fail_json(msg=..., **info) with info = {url,
    #     status: -1}: no dest/elapsed either.
    #   * ConnectionFailure / UnknownUrlScheme - both became info['msg']
    #     with status -1, so the request DID run url_get's own
    #     status == -1 branch, fail_json(msg=info['msg'], url=url,
    #     dest=dest, elapsed=elapsed). Like the download failures below
    #     they carry NO status_code: that key belongs to the non-200
    #     branch (msg="Request failed", status_code=...,
    #     response=...), a different failure entirely.
    private def preflight_failure_result(failure : PluginHelpers::URLPreflight::Failure, url : String, dest : String) : PluginResult
      case failure.kind
      when PluginHelpers::URLPreflight::Kind::MissingLibrary
        PluginResult.new(changed: false, failed: true, msg: failure.msg)
      when PluginHelpers::URLPreflight::Kind::UnknownUrlType
        PluginResult.new(changed: false, failed: true, msg: failure.msg, url: url, status: -1)
      else
        result = PluginResult.new(changed: false, failed: true, msg: failure.msg, url: url, dest: dest, elapsed: 0)
        add_path_info(result, dest)
        result
      end
    end

    private def download_to_dest(
      url : String,
      request_url : String,
      dest_param : String,
      checksum : {String, String}?,
      dest_is_dir = false,
      force = false,
      last_mod_time : Time? = nil,
    ) : PluginResult
      tmp_path = staging_path
      begin
        download_to_dest_staged(tmp_path, url, request_url, dest_param, checksum, dest_is_dir, force, last_mod_time)
      ensure
        cleanup_staging_dir(tmp_path)
      end
    end

    private def download_to_dest_staged(
      tmp_path : String,
      url : String,
      request_url : String,
      dest_param : String,
      checksum : {String, String}?,
      dest_is_dir = false,
      force = false,
      last_mod_time : Time? = nil,
    ) : PluginResult
      started = Time.utc
      info = begin
        download(request_url, tmp_path, force, last_mod_time)
      rescue ex : PluginHelpers::HTTPDownload::FetchError
        File.delete(tmp_path) if File.exists?(tmp_path)
        return not_modified_result(ex.info_msg, url, dest_param, elapsed_since(started)) if ex.status_code == 304
        return fetch_failure_result(ex, url, dest_param, elapsed_since(started))
      rescue ex
        File.delete(tmp_path) if File.exists?(tmp_path)
        return fetch_failure_result(ex, url, dest_param, elapsed_since(started))
      end
      elapsed = elapsed_since(started)
      info = info.as(PluginHelpers::HTTPDownload::Result)

      # Directory dest: the real filename comes from the FINAL response -
      # Content-Disposition first, else the final (post-redirect) URL's
      # basename, real get_url's dest_is_dir ordering (get_url.py: "pluck
      # the URL from the info, since a redirect could have changed it").
      dest = dest_is_dir ? File.join(dest_param, download_filename(info)) : dest_param

      # Real get_url's post-download destination checks, in its own order
      # (get_url.py, between url_get and the checksum verification): an
      # existing dest must be writable and readable, a not-yet-existing
      # one must have an existing, writable parent directory. They run on
      # the STAGED copy, so the request always happens first - which is
      # why a download into an unwritable directory reports the
      # destination error rather than a download error.
      if failure = destination_failure_result(tmp_path, dest, url, elapsed)
        return failure
      end

      if checksum && (mismatch = checksum_mismatch_result(tmp_path, dest, url, checksum, elapsed))
        return mismatch
      end

      # Real bug found benchmarking geerlingguy.jenkins: its own "Add
      # Jenkins apt repository key." task uses `force: true` -
      # Ansible's own get_url module treats force: true as "always
      # re-download, bypassing freshness checks" (Last-Modified/ETag),
      # NOT "always report changed": it still compares the freshly
      # downloaded content against whatever's already at dest: before
      # deciding changed, so a `force: true` task whose URL's content
      # hasn't actually changed still converges to changed: false on a
      # rerun. Unconditionally reporting changed: true here meant EVERY
      # force: true get_url task (a common idiom for "always fetch the
      # latest, but converge if identical" URLs like signing keys)
      # reported changed forever, with no way to ever settle.
      # SHA1 is real get_url's own digest for exactly this comparison
      # (checksum_src = module.sha1(tmpsrc) vs checksum_dest =
      # module.sha1(dest)), regardless of force: or any checksum: param.
      unchanged = File.exists?(dest) && native_checksum(dest, "sha1") == native_checksum(tmp_path, "sha1")

      # Real get_url's SINGLE exit for a 200 response covers both content
      # outcomes (get_url.py's tail): checksum_dest is sha1(dest) when the
      # content matched (changed: false) and unset when the fresh download
      # replaced it (changed: true); msg and status_code are the same on
      # both paths - msg = fetch_url's info['msg'], which real builds as "OK (%s bytes)" % the final response's
      # Content-Length header ("unknown" when the server sent none), and
      # status_code = info['status'] = 200. Live-verified against
      # ansible-core 2.19.11: both a fresh download and a force: true
      # re-download of identical content report
      # msg="OK (1670 bytes)", status_code=200 (the latter with
      # changed: false and checksum_dest set), NOT krikri's old
      # "file already exists and content matches".
      # checksum_dest is sha1 of the PRE-MOVE dest when one existed (real
      # computes it right after the destination checks, before the
      # compare-and-move - so a content-changing re-download reports the
      # OLD content's sha1, live-verified 2.19.11), and unset when dest
      # did not exist.
      checksum_dest = File.exists?(dest) ? native_checksum(dest, "sha1") : nil
      changed = !unchanged
      if unchanged
        File.delete(tmp_path)
      else
        backup_dest_if_requested(dest)
        if failure = move_into_place(tmp_path, dest)
          return failure
        end
      end

      attrs_changed, failure = apply_extended_attributes(dest)
      return failure if failure
      changed = true if attrs_changed

      # status_code = info['status'] = 200 - except for a file:// source,
      # where urllib's file handler sets no status at all and Ansible's
      # final info.get('status', '') serializes as null (live-verified:
      # msg="OK (1670 bytes)", status_code: null).
      status_code = info.final_url.starts_with?("file:") ? nil : 200
      result = PluginResult.new(changed: changed, failed: false,
        msg: "OK (#{info.headers["Content-Length"]? || "unknown"} bytes)",
        checksum_dest: checksum_dest, checksum_src: native_checksum(dest, "sha1"),
        dest: dest, elapsed: elapsed, url: url, src: tmp_path,
        md5sum: native_checksum(dest, "md5"), status_code: status_code,
        key_order: SUCCESS_KEY_ORDER)
      add_path_info(result, dest)
      result
    end

    # Real url_get's 304 branch (the only status besides 200 it accepts):
    # the conditional GET answered "not modified", so the existing dest is
    # already current -
    #   module.exit_json(url=url, dest=dest, changed=False,
    #                    msg=info['msg'], status_code=304, elapsed=elapsed)
    # - where info['msg'] is urllib's own HTTPError str ("HTTP Error 304:
    # Not Modified", reason phrase from the server). NO checksum_src/
    # checksum_dest/md5sum/src: no content came back to hash, and this
    # exit does not spread the module-level result dict. The usual
    # uid/gid/owner/group/mode/state/size keys still attach (Ansible's
    # exit_json runs add_path_info on every exit). Live-verified against
    # ansible-core 2.19.11 over a local http.server.
    private def not_modified_result(msg : String, url : String, dest : String, elapsed = 0) : PluginResult
      result = PluginResult.new(changed: false, failed: false,
        url: url, dest: dest, msg: msg, status_code: 304, elapsed: elapsed)
      add_path_info(result, dest)
      result
    end

    # Real url_get's own branches for a request that never produced a
    # usable body (the Ansible module's fetch_url folds every failure
    # into `info`, and get_url.py branches on info['status'] alone):
    #
    #   * status != 200 and != 304 -> fail_json(msg="Request failed",
    #     status_code=info['status'], response=info['msg'], url=..., dest,
    #     elapsed) - this is the ONLY failure of the two that carries a
    #     status_code, and its response is the HTTPError's own text.
    #   * status == -1 -> fail_json(msg=info['msg'], url, dest, elapsed),
    #     with no status_code at all.
    #
    # `dest` is Ansible's own dest param, i.e. a directory dest stays the
    # directory here (the filename is only derived after a request that
    # came back).
    private def fetch_failure_result(ex : Exception, url : String, dest : String, elapsed = 0) : PluginResult
      result = case ex
               when PluginHelpers::HTTPDownload::FetchError
                 fetch_error_result(ex, url, dest, elapsed)
               else
                 # Anything else on this path died on the socket layer,
                 # where urllib would have wrapped it in a URLError.
                 PluginResult.new(changed: false, failed: true,
                   msg: "Request failed: <urlopen error #{ex.message}>", url: url, dest: dest, elapsed: elapsed)
               end
      add_path_info(result, dest)
      result
    end

    # Ansible's elapsed is whole seconds of wall-clock time spent in the
    # request (a DNS failure on a slow resolver reports 5, not 0).
    private def elapsed_since(started : Time) : Int32
      (Time.utc - started).total_seconds.to_i
    end

    private def fetch_error_result(ex : PluginHelpers::HTTPDownload::FetchError, url : String, dest : String, elapsed = 0) : PluginResult
      case ex.kind
      when PluginHelpers::HTTPDownload::FetchError::Kind::HttpError
        PluginResult.new(changed: false, failed: true, msg: "Request failed",
          status_code: ex.status_code, response: ex.info_msg, url: url, dest: dest, elapsed: elapsed)
      when PluginHelpers::HTTPDownload::FetchError::Kind::ContentCopy
        # get_url.py's own copyfileobj handler: the request was fine, so
        # only elapsed comes with it - no url, no dest.
        PluginResult.new(changed: false, failed: true,
          msg: "failed to create temporary content file: #{ex.reason}", elapsed: elapsed)
      else
        PluginResult.new(changed: false, failed: true, msg: ex.info_msg, url: url, dest: dest, elapsed: elapsed)
      end
    end

    # get_url.py's post-download destination checks, verbatim: an existing
    # dest must be writable and then readable; a dest that does not exist
    # yet needs an existing and then writable parent directory. Returns
    # nil when dest is usable.
    private def destination_failure_result(tmp_path : String, dest : String, url : String, elapsed : Int32) : PluginResult?
      msg = if File.exists?(dest)
              if !File::Info.writable?(dest)
                "Destination #{dest} is not writable"
              elsif !File::Info.readable?(dest)
                "Destination #{dest} is not readable"
              end
            else
              dest_dir = File.dirname(dest)
              if !Dir.exists?(dest_dir)
                "Destination #{dest_dir} does not exist"
              elsif !File::Info.writable?(dest_dir)
                "Destination #{dest_dir} is not writable"
              end
            end
      return nil unless msg

      post_download_failure_result(msg, tmp_path, dest, url, nil, elapsed)
    end

    # The result shape every failure raised AFTER a successful request
    # shares (get_url.py's module-level `result` dict as it stands by
    # then): changed, checksum_dest (still unset - real computes it only
    # after these checks pass), checksum_src of the staged file, dest,
    # elapsed, url and the staged file's own `src` path, plus the dest
    # stat metadata. The staged file is removed, exactly as Ansible's own
    # os.remove(tmpsrc) does on each of these branches.
    private def post_download_failure_result(
      msg : String,
      tmp_path : String,
      dest : String,
      url : String,
      checksum_dest : String?,
      elapsed : Int32,
    ) : PluginResult
      checksum_src = native_checksum(tmp_path, "sha1")
      File.delete(tmp_path) if File.exists?(tmp_path)
      result = PluginResult.new(changed: false, failed: true, msg: msg,
        checksum_dest: checksum_dest, checksum_src: checksum_src,
        dest: dest, elapsed: elapsed, url: url, src: tmp_path)
      add_path_info(result, dest)
      result
    end

    # Verifies the freshly staged download against a provided
    # checksum: tuple; returns a failed PluginResult (staging file
    # cleaned up) on mismatch, nil when it matches or no checksum was
    # given. changed: false like Ansible: by the time the checksum
    # is evaluated the download is still only staged, so nothing has
    # changed yet (and the module-level result dict carries its initial
    # changed=False).
    private def checksum_mismatch_result(tmp_path : String, dest : String, url : String, checksum : {String, String}, elapsed : Int32) : PluginResult?
      algorithm, expected = checksum
      actual = native_checksum(tmp_path, algorithm)
      return nil if actual == expected

      post_download_failure_result(
        "The checksum for #{tmp_path} did not match #{expected}; it was #{actual}.",
        tmp_path, dest, url,
        File.exists?(dest) ? native_checksum(dest, "sha1") : nil,
        elapsed
      )
    end

    # backup: true copies the existing dest aside (timestamp-suffixed,
    # real backup_local's naming shape) before the final move replaces
    # it.
    private def backup_dest_if_requested(dest : String) : Nil
      return unless true?(@params["backup"]?)
      return unless File.exists?(dest)

      File.copy(dest, "#{dest}.#{Time.utc.to_s("%Y-%m-%d@%H:%M:%S")}~")
    end

    # The final atomic move of the staged download onto dest:.
    #
    # unsafe_writes: true is Ansible's escape hatch for targets
    # where the atomic move itself fails (EPERM/EXDEV on docker-mounted
    # single files etc.): fall back to writing dest directly, in place,
    # non-atomically - the same fallback shape copy.cr/lineinfile.cr
    # use. Without the flag the exception propagates (task fails), as
    # before this pass.
    #
    # No parent directory is created here: Ansible never makes one
    # either (get_url.py fails with "Destination <dir> does not exist"
    # in destination_failure_result, above), so a dest under a missing
    # directory is an error, not a mkdir.
    private def move_into_place(tmp_path : String, dest : String) : PluginResult?
      # atomic_move's context capture, read BEFORE the move (issue #911):
      # the staged file replaces dest's inode, so the dest has to be
      # relabelled to the context the write was meant to land on (an
      # existing dest's own, a new one's policy default).
      secontext = prewrite_selinux_context(dest)
      begin
        File.rename(tmp_path, dest)
      rescue ex
        # Ansible's atomic_move copies across devices when rename gives
        # EXDEV (staging dir and dest on different filesystems), so the
        # download still lands instead of failing the task.
        raise ex unless cross_device?(ex) || true?(@params["unsafe_writes"]?)
        unsafe_move_fallback(tmp_path, dest)
      end
      relabel_written_file(dest, secontext)
    end

    private def cross_device?(ex : Exception) : Bool
      ex.is_a?(File::Error) && ex.os_error == Errno::EXDEV
    end

    # Where the download is staged (real get_url's
    # tempfile.mkstemp(dir=tmp_dest); tmp_dest validity was already
    # checked in #execute).
    #
    # Ansible stages in module.tmpdir, which its executor hands the
    # module as _ansible_tmpdir: the per-task ansible-tmp-<epoch>-<pid>-
    # <rand> dir under ~/.ansible/tmp - and reports that staged path back
    # as the result's `src`, never dest-adjacent (live-verified: for a
    # dest: /tmp download ansible-core's src reads
    # /root/.ansible/tmp/ansible-tmp-.../tmpxd0r4kbj, issue #525).
    # Stage in the same shape (unarchive.cr's resolve_src and copy.cr's
    # staged_src_echo mirror it too). The final move may then cross
    # devices, which #move_into_place's EXDEV fallback (Ansible's own
    # atomic_move behavior) covers; the older dest-adjacent staging here
    # existed to keep the rename unconditionally atomic before that
    # fallback landed (issue #475).
    #
    # An explicit tmp_dest: is always honoured (its own validity checks
    # ran in #execute, and a task that names an unwritable one must fail
    # on it rather than quietly stage somewhere else). Staging away from
    # dest also keeps the unwritable-destination behavior: the download
    # succeeds and the task fails with destination_failure_result's
    # message, instead of dying with a permission error on the staging
    # file.
    private def staging_path : String
      if tmp_dest = @params["tmp_dest"]?
        return mkstemp_path(tmp_dest)
      end

      tmpdir = expand_tilde("~/.ansible/tmp/ansible-tmp-#{sprintf("%.7f", Time.local.to_unix_f)}-#{Process.pid}-#{Random.rand(100_000_000_000_000..999_999_999_999_999)}")
      Dir.mkdir_p(tmpdir, mode: 0o700)
      mkstemp_path(tmpdir)
    end

    # Python tempfile.mkstemp() naming with no prefix/suffix: "tmp" +
    # 8 random chars from [a-z0-9_] (tempfile._RandomNameSequence),
    # exclusive-created and retried on a collision, exactly like
    # unarchive.cr's create_staged_download loop. Raw LibC.open because
    # Crystal's File.open mode strings have no exclusive-creation form;
    # mode 0666 (& ~umask via open(2)) keeps the moved dest's mode the
    # same as the previous dest-adjacent staging produced.
    private def mkstemp_path(dir : String) : String
      chars = "abcdefghijklmnopqrstuvwxyz0123456789_"
      10.times do
        name = String.build(11) do |builder|
          builder << "tmp"
          8.times { builder << chars[Random.rand(chars.size)] }
        end
        candidate = File.join(dir, name)
        fd = LibC.open(candidate, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
        next if fd == -1
        LibC.close(fd)
        return candidate
      end
      raise "unable to create a temporary file in #{dir}"
    end

    # The ansible-tmp staging dir is plugin-local (krikri has no
    # executor-level cleanup of it), so drop it as soon as the staged
    # file is gone - rmdir only succeeds on an empty dir, so the
    # best-effort delete can never remove anything else.
    private def cleanup_staging_dir(tmp_path : String) : Nil
      tmpdir = File.dirname(tmp_path)
      return unless File.basename(tmpdir).starts_with?("ansible-tmp-")
      begin
        Dir.delete(tmpdir)
      rescue
        nil
      end
    end

    # tmp_dest: directory the download is staged in before the final move
    # to dest:. Ansible requires it to ALREADY exist and be a
    # directory - a file fails with "%s is a file but should be a
    # directory.", a missing path with "%s directory does not exist."
    # (both carrying the same elapsed: 0 shape as the other download
    # failures).
    private def staging_dir_error(tmp_dest : String) : PluginResult?
      if Dir.exists?(tmp_dest)
        nil
      elsif File.exists?(tmp_dest)
        PluginResult.new(changed: false, failed: true, msg: "#{tmp_dest} is a file but should be a directory.", elapsed: 0)
      else
        PluginResult.new(changed: false, failed: true, msg: "#{tmp_dest} directory does not exist.", elapsed: 0)
      end
    end

    # unsafe_writes fallback: copy the staged file's bytes onto dest
    # directly, in place (preserves dest's inode, so hardlinks/bind-mounts
    # survive - the property the atomic rename sacrifices), then clean up
    # the staging file.
    private def unsafe_move_fallback(tmp_path : String, dest : String) : Nil
      File.open(tmp_path, "r") do |src|
        # perm 0666 mirrors #move_into_place's atomic path: a new dest
        # gets 0666 & ~umask like Ansible's atomic_move; an existing
        # dest's mode is left alone (open(2) ignores perm on overwrite).
        File.open(dest, "w", 0o666) do |dst|
          IO.copy(src, dst)
        end
      end
      File.delete(tmp_path)
    end

    # checksum: "<algo>:<value>" where value is either a literal hex hash or,
    # per Ansible's documented get_url behavior, a URL pointing to a
    # sha*sums-format file (one "<hash>  <filename>" line per file) - in
    # which case the hash for `url`'s own basename is looked up within it.
    # Returns a failed PluginResult when the checksum URL itself cannot be
    # fetched or holds no entry for the target - both of Ansible's own
    # fail_json points (get_url.py, before the main download is attempted).
    private def parse_checksum(checksum_param : String, url : String, dest : String) : {String, String} | PluginResult
      algorithm, _, value = checksum_param.partition(":")
      algorithm = algorithm.downcase

      if value.starts_with?("http://") || value.starts_with?("https://") || value.starts_with?("ftp://") || value.starts_with?("file:")
        # Ansible's own is_url() gate is scheme-based too (http,
        # https, ftp, file), so a "gopher://"-style value is just a
        # (nonsense) literal hash here rather than a second fetch.
        resolved = resolve_checksum_url(value, url, dest)
        return resolved if resolved.is_a?(PluginResult)
        value = resolved.as(String)
      end

      # get_url.py, right after URL resolution: `checksum =
      # re.sub(r'\W+', '', checksum).lower()` strips EVERY non-word
      # character (anything outside [a-zA-Z0-9_]) out of the expected
      # value, then `int(checksum, 16)` rejects whatever is left that is
      # not a hexdigest ("The checksum format is invalid"). The strip is
      # what makes a checksum templated from Ansible's own regex_search
      # backref work at all: regex_search(pattern, '\1') returns a
      # ONE-ELEMENT LIST, and embedding that list in a larger string
      # renders Python's list repr, so SweBarre.opkssh's "Download
      # opkssh" task reaches the module with checksum
      # "sha256:['<hash>']" and real get_url succeeds by stripping the
      # brackets and quotes back out (issue #858: krikri compared the
      # download against the repr verbatim and failed every run). The
      # same stripped value is what the mismatch message reports.
      value = value.gsub(/\W/, "").downcase
      unless value.matches?(/\A[0-9a-f]+\z/)
        result = PluginResult.new(changed: false, failed: true,
          msg: "The checksum format is invalid",
          checksum_dest: nil, checksum_src: nil,
          dest: dest, elapsed: 0, url: url)
        add_path_info(result, dest)
        return result
      end
      {algorithm, value}
    end

    private def resolve_checksum_url(checksum_url : String, target_url : String, dest : String) : String | PluginResult
      tmp_path = "#{Dir.tempdir}/get_url_checksum_#{Process.pid}_#{Random.rand(1_000_000)}.tmp"
      begin
        # Route through #download (not the HTTP helper directly) so a
        # file:// checksum file - also a valid fetch_url source for
        # Ansible - resolves the same way as an http(s) one. Ansible runs
        # the same url_get call for this file, so a failure here carries
        # the same shape as the main download's, naming the CHECKSUM url
        # (that is the request that failed) against the task's dest.
        begin
          download(checksum_url, tmp_path)
        rescue ex
          return fetch_failure_result(ex, checksum_url, dest)
        end

        target_basename = File.basename(URI.parse(target_url).path)
        lines = File.read_lines(tmp_path).map(&.strip).reject(&.empty?)

        # A checksum-url file holding exactly ONE line that is itself
        # just a bare hex hash (no filename at all) - Ansible's own
        # get_url module accepts this shape directly, most commonly seen
        # on Kubernetes release artifacts (dl.k8s.io publishes one
        # "<binary>.sha512" file per binary containing nothing but the
        # hash). Found benchmarking githubixx.kubectl's own "Download
        # kubectl binary" task: the sha*sums-style "<hash> <filename>"
        # parsing below only ever matched a MULTI-file listing, so a
        # single-line hash-only file never matched (no filename token to
        # compare against target_basename at all) and always raised "no
        # checksum entry found", even though the hash itself was right
        # there on its own.
        if lines.size == 1 && lines[0].matches?(/\A[0-9a-fA-F]+\z/)
          return lines[0].downcase
        end

        lines.each do |line|
          # sha*sums format: "<hex-hash> [*]<filename>" (the optional "*"
          # marks binary mode, per sha256sum(1)).
          hash, _, filename = line.partition(/\s+/)
          next if hash.empty? || filename.empty?
          filename = filename.lstrip('*')
          return hash.downcase if File.basename(filename) == target_basename
        end

        # get_url.py: "Unable to find a checksum for file '%s' in '%s'" -
        # a bare fail_json, no url/dest/elapsed (its module-level result
        # dict is not spread here).
        PluginResult.new(changed: false, failed: true,
          msg: "Unable to find a checksum for file '#{target_basename}' in '#{PluginHelpers::UrlMask.mask(checksum_url)}'")
      ensure
        File.delete(tmp_path) if File.exists?(tmp_path)
      end
    end

    private def download(url : String, tmp_path : String, force = false, last_mod_time : Time? = nil) : PluginHelpers::HTTPDownload::Result
      # file:// is a legitimate source for Ansible's get_url too
      # (urllib's FileHandler): a local mirror, a previously-fetched
      # artifact, an offline install. Found via an ad-hoc CLI comparison
      # sweep against Ansible (2026-09-13) - krikri previously
      # failed every file:// URL with "Unsupported scheme: file" because
      # HTTP::Client.new rejects anything non-http(s). Copy the local
      # file into the same staging path the HTTP flow uses, so the rest
      # of the pipeline (checksum verification, changed-comparison,
      # atomic move, attribute reconciliation) is shared unchanged.
      if path = local_file_path(url)
        # urllib's FileHandler opens the file itself and wraps any OSError
        # in a URLError, so the messages below are the ones fetch_url
        # folds into info['msg'] ("Request failed: <urlopen error ...>").
        if !File.exists?(path)
          raise PluginHelpers::HTTPDownload::FetchError.new(
            PluginHelpers::HTTPDownload::FetchError::Kind::UrlError,
            "Request failed: <urlopen error [Errno 2] No such file or directory: '#{path}'>"
          )
        end
        if File.directory?(path)
          raise PluginHelpers::HTTPDownload::FetchError.new(
            PluginHelpers::HTTPDownload::FetchError::Kind::UrlError,
            "Request failed: <urlopen error [Errno 21] Is a directory: '#{path}'>"
          )
        end
        if !local_file_host?(URI.parse(url).host)
          raise PluginHelpers::HTTPDownload::FetchError.new(
            PluginHelpers::HTTPDownload::FetchError::Kind::UrlError,
            "Request failed: <urlopen error file not on local host>"
          )
        end
        # Stage through a fresh 0666 open so the staging file carries the
        # HTTP path's perms (0666 & ~umask, which is what Ansible's
        # atomic_move gives a NEW dest) rather than the source's mode.
        File.open(tmp_path, "w", 0o666) do |staged|
          File.open(path) { |src| IO.copy(src, staged) }
        end
        # urllib's own file handler reports the copied file's size as a
        # Content-length header, and get_url's success msg is built from
        # exactly that header ("OK (<n> bytes)") - live-verified against
        # ansible-core 2.19.11, which for file:// reports
        # msg="OK (1670 bytes)" with status_code: null (info['status'] is
        # unset for a local file, and the final exit_json's
        # info.get('status', '') becomes None).
        file_headers = HTTP::Headers.new
        file_headers["Content-Length"] = File.size(path).to_s
        return PluginHelpers::HTTPDownload::Result.new(final_url: url, headers: file_headers)
      end

      # ftp:// is urllib's FTPHandler, which does a genuine FTP transfer
      # (USER/PASS, PASV, RETR) - Crystal's HTTP::Client rejects any
      # non-http(s) scheme, so without this branch a real ansible task
      # that fetches from an FTP server fails here with "Unsupported
      # scheme: ftp". Everything below mirrors the file:// branch: stage
      # the bytes through the same tmp_path so checksum verification,
      # changed-comparison and the atomic move stay shared.
      if ftp = ftp_url_parts(url)
        return ftp_download(ftp, url, tmp_path, download_options(force, last_mod_time))
      end

      PluginHelpers::HTTPDownload.download_with_info(url, tmp_path, download_options(force, last_mod_time))
    end

    # file:// URL to a local path: nil when the URL isn't a file:// URL
    # (let it fall through to the HTTP helper). Percent-decoding matches
    # urllib's unquote of the path component; a missing path is an error
    # (real: the local file simply cannot be opened).
    private def local_file_path(url : String) : String?
      return nil unless url.starts_with?("file:")
      uri = URI.parse(url)
      return nil unless uri.scheme == "file"
      path = uri.path
      raise "no path in file URL: #{url}" if path.nil? || path.empty?
      URI.decode(path)
    end

    # urllib's FileHandler only serves a file:// URL whose host is EMPTY
    # or resolves to one of this host's own addresses
    # (FileHandler.open_local_file: "not port and
    # _safe_gethostbyname(host) in self.get_names()"), and otherwise ends
    # with URLError('file not on local host'). An explicit port on the
    # host also disqualifies it.
    private def local_file_host?(host : String?) : Bool
      return true if host.nil? || host.empty?
      return false if host.includes?(':')

      Socket::Addrinfo.resolve(host, 80, Socket::Family::UNSPEC, Socket::Type::STREAM, Socket::Protocol::TCP) do |addrinfo|
        return true if addrinfo.ip_address.loopback?
      end
      false
    rescue
      false
    end

    private record FtpTarget, host : String, port : Int32, path : String, user : String?, password : String?

    # ftp:// URL to its pieces: nil for a non-ftp URL (let it fall through
    # to the HTTP helper). The path is kept percent-encoded here and
    # decoded at RETR time, exactly the split urllib uses (Request carries
    # the raw selector, ftp_open's url2request unquotes it).
    private def ftp_url_parts(url : String) : FtpTarget?
      return nil unless url.starts_with?("ftp:")
      uri = URI.parse(url)
      return nil unless uri.scheme == "ftp"
      # getaddrinfo on an empty host fails with EAI_NONAME on glibc, and
      # python's create_connection turns that into exactly the gaierror
      # repr the DNS-failure branch below produces - so an ftp:// URL
      # without a host reports the same thing, not a Crystal-only shape.
      FtpTarget.new(
        host: uri.host || "",
        port: uri.port || 21,
        path: uri.path || "",
        user: uri.user,
        password: uri.password,
      )
    end

    private def ftp_download(target : FtpTarget, url : String, tmp_path : String, options : PluginHelpers::HTTPDownload::Options) : PluginHelpers::HTTPDownload::Result
      control : Socket? = nil
      begin
        control = ftp_connect(target.host, target.port, options.connect_timeout)
        control.read_timeout = options.read_timeout
        control.write_timeout = options.read_timeout
        ftp_transfer(control, target, tmp_path, options.connect_timeout)
      rescue ex
        control.try(&.close)
        # Only the failures urllib itself wraps into "ftp error: %r"
        # (ftplib.all_errors: socket errors, timeouts, EOF) get the python
        # shape; anything else (a staging write failure, say) is not an
        # ftplib error and keeps its own exception.
        if repr = ftp_exception_repr(ex, target)
          raise ftp_fetch_error(repr)
        end
        raise ex
      end
      control.try(&.close)

      # Same Content-Length contract as the file:// branch above: the
      # success msg is built from that header ("OK (<n> bytes)"), and a
      # FTP transfer has no HTTP response to take it from.
      file_headers = HTTP::Headers.new
      file_headers["Content-Length"] = File.size(tmp_path).to_s
      PluginHelpers::HTTPDownload::Result.new(final_url: url, headers: file_headers)
    end

    private def ftp_transfer(control : Socket, target : FtpTarget, tmp_path : String, connect_timeout : Time::Span) : Nil
      code, text = ftp_reply(control)
      ftp_check_reply(code, text)

      user = target.user || "anonymous"
      # ftplib's login defaults: anonymous / 'anonymous@' - the fake
      # address is the historical convention for anonymous FTP passwords.
      password = target.password || (target.user ? "" : "anonymous@")
      ftp_send(control, "USER #{user}")
      code, text = ftp_reply(control)
      if code >= 400
        ftp_reply_error(code, text)
      elsif code >= 300
        # 331 means "need password"; 332 (ACCT) and friends are not
        # supported, same as urllib's plain login sequence.
        ftp_send(control, "PASS #{password}")
        code, text = ftp_reply(control)
        ftp_check_reply(code, text)
      end

      ftp_send(control, "TYPE I")
      code, text = ftp_reply(control)
      ftp_check_reply(code, text)

      ftp_send(control, "PASV")
      code, text = ftp_reply(control)
      ftp_check_reply(code, text)
      pasv_port = ftp_pasv_port(text)

      # ftplib trusts the control connection's own peer address for the
      # data connection (trust_server_pasv_ipv4_address is false by
      # default), not the IP the server echoed inside 227.
      data = ftp_connect(target.host, pasv_port, connect_timeout)
      begin
        data.read_timeout = control.read_timeout
        ftp_send(control, "RETR #{URI.decode(target.path)}")
        code, text = ftp_reply(control)
        if code >= 400
          # The 550/425 arrives on the control channel before any data is
          # copied; the data socket has not been read yet, so closing it
          # here mirrors ftplib's error path.
          data.close
          ftp_reply_error(code, text)
        end
        # Stage through a fresh 0666 open so the staged file carries the
        # HTTP path's perms (0666 & ~umask), like the file:// branch does
        # rather than inheriting anything server-related.
        File.open(tmp_path, "w", 0o666) { |staged| IO.copy(data, staged) }
      ensure
        data.close
      end

      code, text = ftp_reply(control)
      ftp_check_reply(code, text)
      ftp_send(control, "QUIT")
    end

    private def ftp_connect(host : String, port : Int32, connect_timeout : Time::Span) : Socket
      PluginHelpers::SocketConnect.open(host, port, connect_timeout)
    rescue IO::TimeoutError
      # python's connect timeout surfaces as socket.timeout, whose repr is
      # the bare "timeout('timed out')" - not TimeoutError, even though
      # 3.10+ aliases them (observed on rocky python 3.9).
      raise ftp_fetch_error("timeout('timed out')")
    rescue ex : Socket::Addrinfo::Error
      raise ftp_fetch_error(ftp_gaierror_repr(ex) || "OSError('#{ex.message}')")
    rescue ex : Socket::ConnectError
      errno = ex.os_error.as?(Errno) || PluginHelpers::SocketConnect.probe_errno(host, port)
      raise ftp_fetch_error(errno ? ftp_oserror_repr(errno) : "OSError('#{ex.message}')")
    end

    # repr() of the python exception a given failure becomes inside
    # FTPHandler's "ftp error: %r" wrapping: ConnectionRefusedError(111,
    # 'Connection refused') for a refused connect, timeout('timed out')
    # for a timeout, gaierror(-2, ...) for a name-resolution failure.
    # Nil when the exception is not one urllib would have wrapped, so the
    # caller keeps the original.
    private def ftp_exception_repr(ex : Exception, target : FtpTarget) : String?
      case ex
      when PluginHelpers::HTTPDownload::FetchError
        nil
      when IO::TimeoutError
        "timeout('timed out')"
      when Socket::Addrinfo::Error
        ftp_gaierror_repr(ex) || "OSError('#{ex.message}')"
      when Socket::ConnectError
        errno = ex.os_error.as?(Errno) || PluginHelpers::SocketConnect.probe_errno(target.host, target.port)
        errno ? ftp_oserror_repr(errno) : "OSError('#{ex.message}')"
      when Socket::Error
        # A read/write failure on an established control or data socket
        # (reset, broken pipe): ftplib.all_errors includes OSError, so
        # urllib wraps these exactly like a connect failure.
        ex.os_error.as?(Errno).try { |errno| ftp_oserror_repr(errno) }
      end
    end

    private def ftp_gaierror_repr(ex : Socket::Addrinfo::Error) : String?
      code = ex.os_error.as?(Errno).try(&.value.to_i32)
      return nil if code.nil? || code >= 0
      "gaierror(#{code}, '#{String.new(LibC.gai_strerror(code))}')"
    rescue
      nil
    end

    private def ftp_oserror_repr(errno : Errno) : String
      # An ETIMEDOUT errno on the socket layer is what python surfaces as
      # socket.timeout ("timeout('timed out')") - urllib's own timeout
      # fires first, so the errno form never makes it out.
      return "timeout('timed out')" if errno.etimedout?
      "#{ftp_oserror_class(errno)}(#{errno.value}, '#{errno.message}')"
    end

    # python's OSError subclass for an errno - only a few errnos get a
    # dedicated class at all; EHOSTUNREACH and friends stay plain OSError
    # (unlike the str()-form helper in PluginHelpers::SocketConnect, whose class name is
    # never part of the message it builds).
    private def ftp_oserror_class(errno : Errno) : String
      case errno
      when .econnrefused? then "ConnectionRefusedError"
      when .econnreset?   then "ConnectionResetError"
      when .epipe?        then "BrokenPipeError"
      when .eacces?       then "PermissionError"
      else                     "OSError"
      end
    end

    private def ftp_fetch_error(reason : String) : PluginHelpers::HTTPDownload::FetchError
      PluginHelpers::HTTPDownload::FetchError.new(
        PluginHelpers::HTTPDownload::FetchError::Kind::UrlError,
        "Request failed: <urlopen error ftp error: #{reason}>"
      )
    end

    private def ftp_send(io : IO, command : String) : Nil
      io << command << "\r\n"
    end

    # Reads one FTP reply line ("NNN text"); nil at EOF (a control
    # connection that closed under us - ftplib's own EOFError case).
    private def ftp_read_line(io : IO) : String?
      line = io.gets('\n')
      return nil unless line
      line.chomp
    end

    # Reads a complete reply, absorbing multiline responses ("NNN-..."
    # continuations until the "NNN " terminator), and returns code + text.
    private def ftp_reply(io : IO) : {Int32, String}
      line = ftp_read_line(io) || raise ftp_fetch_error("EOFError()")
      raise ftp_fetch_error("error_proto('#{ftp_repr_escape(line)}')") unless line.matches?(/\A\d{3}[ -]/)
      code = line[0..2].to_i
      while line[3] == '-'
        line = ftp_read_line(io) || raise ftp_fetch_error("EOFError()")
      end
      text = line.size > 4 ? line[4..] : ""
      {code, text}
    end

    private def ftp_check_reply(code : Int32, text : String) : Nil
      ftp_reply_error(code, text) if code >= 400
    end

    # ftplib's getresp maps the reply's leading digit to its error class:
    # 4xx -> error_temp, 5xx -> error_perm, with the full reply line as
    # the message - so the repr carries "550 ..." inside the quotes.
    private def ftp_reply_error(code : Int32, text : String) : NoReturn
      cls = code >= 500 ? "error_perm" : "error_temp"
      raise ftp_fetch_error("#{cls}('#{code} #{ftp_repr_escape(text)}')")
    end

    # python repr's single-quote escaping of the text inside the error
    # reprs; the block form avoids gsub's backreference processing of the
    # replacement string.
    private def ftp_repr_escape(text : String) : String
      text.gsub("'") { "\\'" }
    end

    # parse227's "(h1,h2,h3,h4,p1,p2)" form; anything else is
    # error_proto in ftplib, kept here for the same reason.
    private def ftp_pasv_port(text : String) : Int32
      m = text.match(/\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)/) ||
          raise ftp_fetch_error("error_proto('#{ftp_repr_escape(text)}')")
      m[5].to_i * 256 + m[6].to_i
    end

    private def download_options(force = false, last_mod_time : Time? = nil) : PluginHelpers::HTTPDownload::Options
      PluginHelpers::HTTPDownload::Options.new(
        max_redirects: MAX_REDIRECTS,
        connect_timeout: timeout_span,
        read_timeout: timeout_span,
        headers: request_headers(force, last_mod_time),
        verify_tls: true?(@params["validate_certs"]?, default: true),
        username: @params["url_username"]?,
        password: @params["url_password"]?,
        # Basic auth timing: real get_url's force_basic_auth default is
        # false - an unauthenticated first request, then one retry WITH
        # the header on a 401 challenge. true sends it up front instead.
        force_basic_auth: true?(@params["force_basic_auth"]?, default: false),
        client_cert: @params["client_cert"]?,
        client_key: @params["client_key"]?,
        ciphers: tls_ciphers,
        unredirected_headers: unredirected_headers,
      )
    end

    # http.client.putheader rejects a name whose first char is ':' or
    # whitespace, or which contains ':', CR or LF (http/client.py's
    # rb'[^:\s][^:\r\n]*' fullmatch), before any connection is made, and
    # fetch_url folds that ValueError into status -1 with the bare message.
    # urllib's do_open .title()-cases every header name before putheader, so
    # the name in the message is the TITLE-CASED form ("Cookie:oraclelicense"
    # -> b'Cookie:Oraclelicense', KAMI911.java_oracle_jdk11's Oracle cookie
    # trick).
    private def invalid_header_name(headers : Hash(String, String)?) : String?
      return nil if headers.nil?
      headers.each_key do |key|
        return key if key.empty? || key[0] == ':' || key[0].whitespace? || key.includes?(':') || key.includes?('\r') || key.includes?('\n')
      end
      nil
    end

    # Python str.title(): uppercase each letter that follows a non-letter
    # (or nothing), lowercase the rest. NOT Crystal's titleize, which leaves
    # later words untouched ("cookie:oraclelicense".titleize keeps
    # "oraclelicense" lowercase where Python's .title() gives
    # "Oraclelicense").
    private def python_title(name : String) : String
      String.build do |builder|
        prev_alpha = false
        name.each_char do |char|
          if char.letter?
            builder << (prev_alpha ? char.downcase : char.upcase)
            prev_alpha = true
          else
            builder << char
            prev_alpha = false
          end
        end
      end
    end

    # Real get_url's headers: is a dict param, so a plain string is converted
    # by Ansible's check_type_dict (ansible/module_utils/common/validation.py)
    # at arg-spec validation, BEFORE the module body: a "{"-prefixed string
    # must parse as a dict (JSON first, then Python's literal_eval), a string
    # containing "=" is parsed as comma/space-separated key=value fields, and
    # anything else fails validation with "argument 'headers' is of type str
    # and we were unable to convert to dict: ...". That conversion is what
    # makes the classic Oracle cookie trick
    # `headers: Cookie:oraclelicense=accept-securebackup-cookie`
    # (KAMI911.java_oracle_jdk11) land as the single key "Cookie:oraclelicense"
    # (split on the first "="), which urllib then rejects with "Invalid header
    # name b'Cookie:Oraclelicense'" before any request is made. Krikri used to
    # split such strings on ":" instead ("Cookie" / "oraclelicense=..."),
    # producing a perfectly legal request - and a completely different
    # failure (the dead URL's 404) where Ansible never requests at all.
    #
    # Returns {dict, nil} when the param converts, {nil, msg} when the
    # conversion itself fails, {nil, nil} when headers is absent.
    private def converted_headers : {Hash(String, String)?, String?}
      raw = @params["headers"]?
      return {nil, nil} unless raw

      # A dict param value arrives here as its JSON text (module-arg
      # finalization stringifies every param into this plugin's
      # Hash(String, String) @params) - real bug found benchmarking
      # caddy_ansible.caddy_ansible: `headers: '{{ caddy_github_headers }}'`
      # (a real dict, `{}` by default) must be passed through as a dict, not
      # split on "," into a header literally NAMED "{}".
      parsed = JSON.parse(raw) rescue nil
      if parsed
        if dict = parsed.as_h?
          headers = {} of String => String
          dict.each do |key, value|
            headers[key] = value.as_s? || value.to_s
          end
          return {headers, nil}
        end
        # A JSON-parsable STRING is just a string whose text happens to look
        # like JSON (e.g. a `| to_json` result): real check_type_dict sees a
        # plain python str and runs the string branches below on it verbatim.
        # Any other JSON type means the YAML value itself wasn't a string or
        # dict (a list, number, bool...): check_type_dict rejects those types
        # outright.
        unless parsed.as_s?
          pytype = case parsed.raw
                   when Array(JSON::Any) then "list"
                   when Int64            then "int"
                   when Float64          then "float"
                   when Bool             then "bool"
                   else                       "NoneType"
                   end
          return {nil, "argument 'headers' is of type #{pytype} and we were unable to convert to dict: <class '#{pytype}'> cannot be converted to a dict"}
        end
      end

      if raw.starts_with?('{')
        # JSON failed but the string looks like an object: real ansible falls
        # back to Python's ast.literal_eval, which accepts the single-quoted
        # Python dict literal form ("{'a': 'b'}").
        if dict = PythonLiteral.dict_json(raw).try(&.as_h?)
          headers = {} of String => String
          dict.each do |key, value|
            headers[key] = value.as_s? || value.to_s
          end
          return {headers, nil}
        end
        return {nil, "argument 'headers' is of type str and we were unable to convert to dict: unable to evaluate string as dictionary"}
      end

      if raw.includes?('=')
        if dict = parse_kv_dict(raw)
          return {dict, nil}
        end
        return {nil, "argument 'headers' is of type str and we were unable to convert to dict: unable to evaluate string in the \"key=value\" format as dictionary"}
      end

      {nil, "argument 'headers' is of type str and we were unable to convert to dict: dictionary requested, could not parse JSON or key=value"}
    end

    # The "k=v,k2=v2" half of check_type_dict (validation.py): fields split on
    # unquoted commas and spaces (quote- and backslash-aware, like the Python
    # state machine), each field then split on the first "=" - a field without
    # one fails the whole conversion.
    private def parse_kv_dict(raw : String) : Hash(String, String)?
      fields = [] of String
      buffer = ""
      in_quote = nil.as(Char?)
      in_escape = false
      raw.strip.each_char do |char|
        if in_escape
          buffer += char.to_s
          in_escape = false
        elsif char == '\\'
          in_escape = true
        elsif in_quote.nil? && (char == '\'' || char == '"')
          in_quote = char
        elsif in_quote == char
          in_quote = nil
        elsif in_quote.nil? && (char == ',' || char == ' ')
          fields << buffer unless buffer.empty?
          buffer = ""
        else
          buffer += char.to_s
        end
      end
      fields << buffer unless buffer.empty?

      dict = {} of String => String
      fields.each do |field|
        return nil unless field.includes?('=')
        key, _, value = field.partition('=')
        dict[key] = value
      end
      dict
    end

    private def python_bytes_repr(name : String) : String
      "b'#{name.gsub("\\", "\\\\").gsub("'", "\\'")}'"
    end

    private def timeout_span : Time::Span
      (@params["timeout"]? || "10").to_i.seconds
    end

    # ciphers: real get_url types it as a LIST of cipher names joined
    # with ":" (module doc: "all ciphers are joined in order with C(:)").
    # The param arrives here as its JSON text (["TLS_AES_256_GCM_SHA384",...]),
    # so decode the list; a plain string passes through untouched.
    private def tls_ciphers : String?
      raw = @params["ciphers"]? || return nil
      begin
        list = Array(String).from_json(raw)
        list.empty? ? nil : list.join(":")
      rescue
        raw
      end
    end

    private def unredirected_headers : Array(String)
      raw = @params["unredirected_headers"]?
      return [] of String unless raw
      begin
        Array(String).from_json(raw).map(&.downcase)
      rescue
        [] of String
      end
    end

    private def request_headers(force = false, last_mod_time : Time? = nil) : HTTP::Headers
      headers = HTTP::Headers.new
      headers["User-Agent"] = @params["http_agent"]? || "ansible-httpget"

      # Real fetch_url's cache-control branch:
      # a forced request carries "cache-control: no-cache"; an unforced
      # one whose dest already exists carries If-Modified-Since (dest's
      # mtime, RFC 1123 with seconds precision, like Ansible's
      # rfc2822_date_string(timetuple(), 'GMT')). User-supplied headers:
      # still come after and may override, same order as real.
      if force
        headers["Cache-Control"] = "no-cache"
      elsif time = last_mod_time
        headers["If-Modified-Since"] = Time::Format::HTTP_DATE.format(time)
      end

      # decompress: false (real get_url's decompress param, default true)
      # suppresses gzip at the REQUEST level, same approach uri.cr uses:
      # Crystal's HTTP::Client otherwise always offers gzip/deflate and
      # transparently inflates the response, while Ansible instead
      # decides per-response. Asking the server for identity achieves the
      # same observable result: the file gets exactly the bytes the
      # server meant to send, undecoded. A user-supplied Accept-Encoding
      # wins, matching real header-override order.
      if !true?(@params["decompress"]?, default: true) && !headers.has_key?("Accept-Encoding")
        headers["Accept-Encoding"] = "identity"
      end

      # The headers param was already converted (or rejected) by
      # converted_headers during execute - see it for the check_type_dict
      # semantics; a failed conversion never reaches a request.
      if user_headers = converted_headers[0]
        user_headers.each do |key, value|
          headers[key] = value
        end
      end

      headers
    end

    # dest:'s mode:/owner:/group: file-common args, mirroring copy.cr's
    # apply_file_attributes (octal-or-symbolic mode split, native chown
    # via System::User/Group lookups, best-effort on permission
    # failures) - except the application ORDER follows basic.py's
    # set_fs_attributes_if_different (owner, group, then mode), which
    # copy.cr's own copy does not. Returns true when anything actually
    # changed on disk.
    private def apply_file_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

      # basic.py's set_fs_attributes_if_different applies owner, then
      # group, then mode (each setter failing the task before the next
      # runs). krikri used to chmod FIRST, so a get_url with both mode:
      # and an unresolvable owner failed with the chmod already applied
      # (round29888377 kilip.chezmoi: mode "0777" + owner "" reported
      # mode "0777" in the failure's stat block where ansible reported
      # the download's 0644 - and the now-executable dest made the
      # role's follow-up command task succeed where ansible hit
      # "Permission denied"). The chmod therefore only runs after BOTH
      # chown lookups have resolved.
      uid = -1
      gid = -1

      # A present owner:/group: value (explicit empty string included)
      # is always resolved - and an unresolvable name fails the task
      # like Ansible's basic.py (round900811 kilip.chezmoi) -
      # instead of the old `&&`-short-circuit that silently skipped the
      # chown whenever the lookup came back empty.
      if owner = @params["owner"]?
        uid = resolve_owner_uid(owner)
      end

      if group = @params["group"]?
        gid = resolve_group_gid(group)
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      if mode = @params["mode"]?
        begin
          # All-digit mode strings parse as octal (leading zero or not);
          # anything symbolic goes to the real chmod binary - see
          # copy.cr's own apply_file_attributes for the full story.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          else
            Process.run("chmod", [mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
          end
        rescue File::Error
          # Mode setting failed, continue anyway
        end
      end

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue File::Error
      # A chown/chmod failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches copy.cr's own rescue.
      false
    end

    # attributes:/attr: - chattr-style flags (e.g. "+i" for immutable),
    # Ansible's `attributes` param and its `attr` alias. Mirrors
    # copy.cr's proven implementation exactly (same helper names, same
    # semantics - see copy.cr's attr_args for the full rationale).
    private def attr_args : {Char, String}?
      raw = @params["attr"]? || @params["attributes"]?
      return nil unless raw
      raw = raw.strip
      return nil if raw.empty?
      if raw[0] == '-' || raw[0] == '+'
        {raw[0], raw[1..]}
      else
        {'=', raw}
      end
    end

    # The file's current chattr flags via `lsattr -d` (dash-padding
    # stripped); an lsattr failure (missing binary, tmpfs) reads as empty
    # flags rather than an error - mirrors copy.cr/current_attr_flags.
    private def current_attr_flags(path : String) : String
      result = remote_exec("lsattr -d #{shell_single_quote(path)}")
      return "" unless result[:exit_code] == 0
      fields = result[:stdout].strip.split
      return "" if fields.empty?
      fields[0].delete('-').strip
    end

    # Changed-check mirroring Ansible's set_attributes_if_different:
    # changed when the current flag string differs from the requested
    # letters OR the request is '-'-prefixed (ansible/ansible#33745).
    private def attr_changed?(path : String) : Bool
      parsed = attr_args
      return false unless parsed
      mod, flags = parsed
      return false if flags.empty?
      current_attr_flags(path) != flags || mod == '-'
    end

    # Applies the attributes: param via the real chattr binary and fails
    # the task (like Ansible's fail_json(msg='chattr failed')) when
    # chattr exits nonzero or writes to stderr. Returns {changed,
    # failure} - mirrors copy.cr's apply_attr.
    private def apply_attr(path : String) : {Bool, PluginResult?}
      return {false, nil} unless attr_changed?(path)

      parsed = attr_args
      return {false, nil} unless parsed
      mod, flags = parsed

      result = remote_exec("chattr #{mod}#{flags} #{shell_single_quote(path)}")
      if result[:exit_code] != 0 || !result[:stderr].strip.empty?
        return {false, PluginResult.new(changed: false, failed: true, msg: "chattr failed - Error while setting attributes: #{result[:stdout]}#{result[:stderr]}")}
      end

      {true, nil}
    end

    # seuser:/serole:/setype:/selevel: - the SELinux file context, applied
    # through BasePlugin's shared helpers (the same ones file, copy,
    # template and stat use), so a context change is DETECTED and counted
    # as changed instead of blindly re-applied, "_default" resolves
    # through matchpathcon, and the parts merge into the file's current
    # context the way basic.py's set_context_if_different does. Returns
    # {changed, failure}; the failure is that fail_json's shape
    # (msg='invalid selinux context: <err>', path, cur_context,
    # new_context, input_was).
    private def apply_secontext(path : String, check_mode : Bool = false) : {Bool, PluginResult?}
      return {false, nil} unless pending = pending_secontext_change(path)
      current, desired = pending

      return {true, nil} if check_mode

      if err = set_selinux_context(path, desired)
        return {false, selinux_context_failure(path, err, current, desired, secontext_input_was)}
      end

      {true, nil}
    end

    # Basic.py's set_fs_attributes_if_different order: SELinux context
    # first, then mode/owner/group (#apply_file_attributes), then the
    # chattr flags. Returns {changed, failure}: failure a failed
    # PluginResult when the chattr/chcon call itself errored (both fail
    # the task like Ansible - neither is silently swallowed the way a
    # chmod/chown EPERM is).
    private def apply_extended_attributes(path : String) : {Bool, PluginResult?}
      secontext_changed, failure = apply_secontext(path)
      return {false, failure} if failure

      begin
        changed = apply_file_attributes(path)
      rescue ex : OwnerLookupFailure
        # Ansible's set_owner_if_different fails with fail_json(path=path,
        # ...), and fail_json attaches the dest's stat info, so the failure
        # carries path/uid/gid/owner/group/mode/state/size; letting the
        # exception reach run_and_capture would drop them all.
        failure = PluginResult.new(changed: false, failed: true, msg: ex.message || "owner lookup failed")
        add_path_info(failure, path)
        failure.extra["path"] = JSON::Any.new(path)
        return {false, failure}
      end
      changed = true if secontext_changed

      attr_changed, failure = apply_attr(path)
      return {false, failure} if failure
      changed = true if attr_changed

      {changed, nil}
    end

    # Real get_url's url_filename: basename of the URL's path component,
    # 'index.html' when the path has no basename (its own documented
    # fallback). Python's os.path.basename keeps the empty tail of a
    # trailing-slash path (os.path.basename("/ffmpeg/") == ""), so Ansible
    # saves such downloads as index.html; Crystal's File.basename strips
    # the slash and would name them after the directory instead. Found
    # benchmarking ucsdlib.ffmpeg (issue #231): its
    # https://johnvansickle.com/ffmpeg/ fetch into a directory dest
    # landed at <dir>/ffmpeg, so the role's next grep on index.html
    # had nothing to find.
    private def url_filename(url : String) : String
      path = URI.parse(url).path || ""
      slash = path.rindex("/")
      fn = slash ? path[(slash + 1)..] : path
      fn.empty? ? "index.html" : fn
    end

    # Directory-dest filename from a completed download: the final
    # response's Content-Disposition filename param first (basename'd, as
    # real extract_filename_from_headers does to block traversal), else
    # the final post-redirect URL's basename.
    private def download_filename(info : PluginHelpers::HTTPDownload::Result) : String
      if (disposition = info.headers["Content-Disposition"]?) &&
         (fn = content_disposition_filename(disposition)) && !fn.empty?
        return File.basename(fn)
      end
      url_filename(info.final_url)
    end

    # Extracts the filename param from a Content-Disposition value:
    # `attachment; filename="name.tar.gz"`, also tolerating an RFC 5987
    # filename* form (charset'lang'percent-encoded). Not a full
    # email.message.Message#get_param replacement, but covers what real
    # servers actually send (apache.org's dyn/closer.cgi among them).
    private def content_disposition_filename(value : String) : String?
      value.split(';').each do |part|
        name, _, param = part.strip.partition('=')
        next if param.empty?
        if name.downcase == "filename*"
          raw = param.strip
          raw = raw[1..-2] if raw.size >= 2 && raw.starts_with?('"') && raw.ends_with?('"')
          encoded = raw.split("'")[-1]?
          return URI.decode(encoded) if encoded && !encoded.empty?
        elsif name.downcase == "filename"
          param = param.strip
          param = param[1..-2] if param.size >= 2 && param.starts_with?('"') && param.ends_with?('"')
          return param
        end
      end
      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::GetUrlPlugin.new(config)
plugin.run

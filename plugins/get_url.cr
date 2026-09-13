#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/http_download"

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
    MAX_REDIRECTS = 10

    def execute : PluginResult
      url = @params["url"]?
      dest = @params["dest"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: url") unless url
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: dest") unless dest

      dest = expand_tilde(dest)
      dest = File.directory?(dest) ? File.join(dest, File.basename(URI.parse(url).path)) : dest

      checksum = resolved_checksum(url)
      return checksum if checksum.is_a?(PluginResult)

      force = true?(@params["force"]?, default: false)

      if File.exists?(dest) && !force
        if skip_result = check_existing_dest(dest, checksum)
          return skip_result
        end
        # Checksum given but doesn't match: fall through and re-download,
        # regardless of force - the checksum is its own freshness check,
        # matching real Ansible's get_url behavior.
      end

      if true?(@params["check_mode"]?)
        result = PluginResult.new(changed: true, failed: false, msg: "would download #{url} to #{dest} (check mode)", dest: dest)
        add_path_info(result, dest)
        return result
      end

      # tmp_dest is validated up front (real get_url's url_get does it
      # right before staging) so a bad tmp_dest fails before any request.
      if (tmp_dest_param = @params["tmp_dest"]?) && (tmp_error = staging_dir_error(tmp_dest_param))
        return tmp_error
      end

      download_to_dest(url, dest, checksum)
    end

    # Parses the checksum: param (if any) into its {algorithm, hash}
    # tuple, or a failed PluginResult on resolution failure. An empty
    # checksum: string is real Ansible's own signal for "no checksum
    # given" (its get_url module explicitly treats a falsy checksum the
    # same as an absent one), NOT a value to actually verify against -
    # found via juju4.openobserve's own `checksum: "{{ openobserve_hash |
    # default(omit) }}"` where openobserve_hash DEFAULTS to "" (a real,
    # DEFINED empty string, not undefined) for this OS/arch combination,
    # so default(omit) never fires for either engine - both receive
    # checksum: "" identically. Without this, krikri tried to verify the
    # real download against an empty expected hash and failed every
    # single time ("checksum mismatch: expected , got <real hash>")
    # where real Ansible correctly skips verification. A resolution
    # failure carries status_code: -1, the shape real Ansible's
    # fetch_url-based url_get produces when a request dies before any
    # HTTP response (its fail_json spreads info['status'], initialized
    # to -1, into status_code), so a role's registered-result guards see
    # identical keys.
    private def resolved_checksum(url : String) : {String, String}? | PluginResult
      checksum_param = @params["checksum"]?
      return nil if checksum_param.nil? || checksum_param.strip.empty?

      begin
        parse_checksum(checksum_param, url)
      rescue ex
        PluginResult.new(changed: false, failed: true, msg: "failed to resolve checksum: #{ex.message}", status_code: -1)
      end
    end

    # Returns a PluginResult if the download can be skipped (dest already
    # present and, when a checksum was given, matching), nil to signal
    # "proceed with download".
    #
    # File-common attribute reconciliation on this path mirrors real
    # Ansible's get_url exactly (live-read against ansible-core 2.19.4's
    # module source): set_fs_attributes_if_different runs even when the
    # download is skipped, and a stale attribute flips the result to
    # changed: true with msg "file already exists but file attributes
    # changed".
    private def check_existing_dest(dest : String, checksum : {String, String}?) : PluginResult?
      check_mode = true?(@params["check_mode"]?)

      if checksum
        algorithm, expected = checksum
        actual = native_checksum(dest, algorithm)
        return nil unless actual == expected
      end

      attrs_changed = false
      unless check_mode
        attrs_changed, failure = apply_extended_attributes(dest)
        return failure if failure
      end

      if checksum
        result = PluginResult.new(changed: attrs_changed || false, failed: false, msg: attrs_changed ? "file already exists but file attributes changed" : "file already exists", dest: dest, checksum_src: nil, checksum_dest: nil)
        add_path_info(result, dest)
        result
      else
        result = PluginResult.new(changed: attrs_changed || false, failed: false, msg: attrs_changed ? "file already exists but file attributes changed" : "file already exists (use force=yes to overwrite)", dest: dest)
        add_path_info(result, dest)
        result
      end
    end

    private def download_to_dest(url : String, dest : String, checksum : {String, String}?) : PluginResult
      tmp_path = staging_path(dest)
      begin
        download(url, tmp_path)
      rescue ex
        File.delete(tmp_path) if File.exists?(tmp_path)
        # Same fetch_url contract as the checksum rescue above: real Ansible
        # includes status_code: -1 (plus url/dest/elapsed) in get_url's
        # download-failure result, so `when: r.status_code == -1` behaves
        # identically here.
        failure_result = PluginResult.new(changed: false, failed: true, msg: "failed to download #{url}: #{ex.message}", status_code: -1, url: url, dest: dest, elapsed: 0)
        add_path_info(failure_result, dest)
        return failure_result
      end

      if checksum && (mismatch = checksum_mismatch_result(tmp_path, checksum))
        return mismatch
      end

      # Real bug found benchmarking geerlingguy.jenkins: its own "Add
      # Jenkins apt repository key." task uses `force: true` - real
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
      unchanged = File.exists?(dest) && native_checksum(dest, "sha256") == native_checksum(tmp_path, "sha256")

      if unchanged
        File.delete(tmp_path)
        attrs_changed, failure = apply_extended_attributes(dest)
        return failure if failure
        result = PluginResult.new(changed: attrs_changed, failed: false, msg: "file already exists and content matches", dest: dest, md5sum: native_checksum(dest, "md5"))
        add_path_info(result, dest)
        return result
      end

      backup_dest_if_requested(dest)

      move_into_place(tmp_path, dest)

      _attrs_changed, failure = apply_extended_attributes(dest)
      return failure if failure

      result = PluginResult.new(changed: true, failed: false, msg: "OK", dest: dest, checksum_src: native_checksum(dest, "sha1"), checksum_dest: nil, md5sum: native_checksum(dest, "md5"))
      add_path_info(result, dest)
      result
    end

    # Verifies the freshly staged download against a provided
    # checksum: tuple; returns a failed PluginResult (staging file
    # cleaned up) on mismatch, nil when it matches or no checksum was
    # given.
    private def checksum_mismatch_result(tmp_path : String, checksum : {String, String}) : PluginResult?
      algorithm, expected = checksum
      actual = native_checksum(tmp_path, algorithm)
      return nil if actual == expected

      File.delete(tmp_path) if File.exists?(tmp_path)
      PluginResult.new(changed: false, failed: true, msg: "checksum mismatch: expected #{expected}, got #{actual}")
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
    # unsafe_writes: true is real Ansible's escape hatch for targets
    # where the atomic move itself fails (EPERM/EXDEV on docker-mounted
    # single files etc.): fall back to writing dest directly, in place,
    # non-atomically - the same fallback shape copy.cr/lineinfile.cr
    # use. Without the flag the exception propagates (task fails), as
    # before this pass.
    private def move_into_place(tmp_path : String, dest : String) : Nil
      dest_dir = File.dirname(dest)
      Dir.mkdir_p(dest_dir) unless Dir.exists?(dest_dir)
      begin
        File.rename(tmp_path, dest)
      rescue ex
        raise ex unless true?(@params["unsafe_writes"]?)
        unsafe_move_fallback(tmp_path, dest)
      end
    end

    # Where the download is staged (real get_url's
    # tempfile.mkstemp(dir=tmp_dest); tmp_dest validity was already
    # checked in #execute). When absent, the staging file goes NEXT TO
    # dest rather than in the system tmp dir: same-filesystem staging is
    # what makes the final File.rename unconditionally atomic, where
    # real Ansible (which starts from the system tmp dir) needs its own
    # EXDEV fallback inside atomic_move to reach the same place.
    private def staging_path(dest : String) : String
      base = @params["tmp_dest"]? || File.dirname(dest)
      File.join(base, ".get_url_#{Process.pid}_#{Random::Secure.hex(8)}.tmp")
    end

    # tmp_dest: directory the download is staged in before the final move
    # to dest:. Real Ansible requires it to ALREADY exist and be a
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
        File.open(dest, "w") do |dst|
          IO.copy(src, dst)
        end
      end
      File.delete(tmp_path)
    end

    # checksum: "<algo>:<value>" where value is either a literal hex hash or,
    # per real Ansible's documented get_url behavior, a URL pointing to a
    # sha*sums-format file (one "<hash>  <filename>" line per file) - in
    # which case the hash for `url`'s own basename is looked up within it.
    private def parse_checksum(checksum_param : String, url : String) : {String, String}
      algorithm, _, value = checksum_param.partition(":")
      algorithm = algorithm.downcase

      if value.starts_with?("http://") || value.starts_with?("https://")
        {algorithm, resolve_checksum_url(value, url)}
      else
        {algorithm, value.downcase}
      end
    end

    private def resolve_checksum_url(checksum_url : String, target_url : String) : String
      tmp_path = "#{Dir.tempdir}/get_url_checksum_#{Process.pid}_#{Random.rand(1_000_000)}.tmp"
      begin
        PluginHelpers::HTTPDownload.download(checksum_url, tmp_path, download_options)

        target_basename = File.basename(URI.parse(target_url).path)
        lines = File.read_lines(tmp_path).map(&.strip).reject(&.empty?)

        # A checksum-url file holding exactly ONE line that is itself
        # just a bare hex hash (no filename at all) - real Ansible's own
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

        raise "no checksum entry for #{target_basename} found in #{checksum_url}"
      ensure
        File.delete(tmp_path) if File.exists?(tmp_path)
      end
    end

    private def download(url : String, tmp_path : String) : Nil
      # Delegates to the shared HTTPDownload helper (also used by
      # deb822_repository.cr) so both plugins share one redirect-following,
      # binary-safe download implementation. get_url's own extra knobs
      # (timeout, validate_certs, basic auth, custom headers) map onto the
      # helper's Options.
      PluginHelpers::HTTPDownload.download(url, tmp_path, download_options)
    end

    private def download_options : PluginHelpers::HTTPDownload::Options
      PluginHelpers::HTTPDownload::Options.new(
        max_redirects: MAX_REDIRECTS,
        connect_timeout: timeout_span,
        read_timeout: timeout_span,
        headers: request_headers,
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

    private def request_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["User-Agent"] = @params["http_agent"]? || "ansible-httpget"

      # decompress: false (real get_url's decompress param, default true)
      # suppresses gzip at the REQUEST level, same approach uri.cr uses:
      # Crystal's HTTP::Client otherwise always offers gzip/deflate and
      # transparently inflates the response, while real Ansible instead
      # decides per-response. Asking the server for identity achieves the
      # same observable result: the file gets exactly the bytes the
      # server meant to send, undecoded. A user-supplied Accept-Encoding
      # wins, matching real header-override order.
      if !true?(@params["decompress"]?, default: true) && !headers.has_key?("Accept-Encoding")
        headers["Accept-Encoding"] = "identity"
      end

      if headers_param = @params["headers"]?
        # headers: real Ansible documents (and accepts) this as a real
        # DICT, not just the comma-separated "key:value,key2:value2"
        # string this plugin originally only supported. A dict param
        # value arrives here as its JSON text (module-arg finalization
        # stringifies every param into this plugin's Hash(String,
        # String) @params) - real bug found benchmarking caddy_ansible.
        # caddy_ansible's own `headers: '{{ caddy_github_headers }}'`
        # (caddy_github_headers a real dict, `{}` by default, built via
        # `| combine(...)` when a token is set): the literal 2-character
        # text "{}" was split on "," (["{}"]  ) then partitioned on ":"
        # (key="{}", value=""), setting an HTTP header literally NAMED
        # "{}" with an empty value - GitHub's API rejected the request
        # outright with 400 Bad Request instead of the header-less
        # request real Ansible actually sends for an empty dict.
        parsed_dict = (JSON.parse(headers_param).as_h? rescue nil)
        if parsed_dict
          parsed_dict.each do |key, value|
            headers[key] = value.as_s? || value.to_s
          end
        else
          headers_param.split(",").each do |pair|
            key, _, value = pair.partition(":")
            headers[key.strip] = value.strip unless key.blank?
          end
        end
      end

      headers
    end

    # dest:'s mode:/owner:/group: file-common args, mirroring copy.cr's
    # proven apply_file_attributes (octal-or-symbolic mode split, native
    # chown via System::User/Group lookups, best-effort on permission
    # failures). Returns true when anything actually changed on disk.
    private def apply_file_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

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
        rescue ex : File::Error
          # Mode setting failed, continue anyway
        end
      end

      uid = -1
      gid = -1

      if (owner = @params["owner"]?) && (user = System::User.find_by?(name: owner))
        uid = user.id.to_i
      end

      if (group = @params["group"]?) && (grp = System::Group.find_by?(name: group))
        gid = grp.id.to_i
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue ex : File::Error
      # A chown/chmod failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches copy.cr's own rescue.
      false
    end

    # attributes:/attr: - chattr-style flags (e.g. "+i" for immutable),
    # real Ansible's `attributes` param and its `attr` alias. Mirrors
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

    # Changed-check mirroring real Ansible's set_attributes_if_different:
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
    # the task (like real Ansible's fail_json(msg='chattr failed')) when
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

    # seuser:/serole:/setype:/selevel: - SELinux file context via `chcon`,
    # mirroring copy.cr's apply_selinux_context: skipped entirely (not
    # even attempted) when SELinux isn't enabled on the target, matched
    # via the standard /sys/fs/selinux/enforce selinuxfs check.
    private def apply_selinux_context(dest : String) : PluginResult?
      return nil unless File.exists?("/sys/fs/selinux/enforce")

      flags = [] of String
      flags << "-u #{@params["seuser"]}" if @params["seuser"]?
      flags << "-r #{@params["serole"]}" if @params["serole"]?
      flags << "-t #{@params["setype"]}" if @params["setype"]?
      flags << "-l #{@params["selevel"]}" if @params["selevel"]?
      return nil if flags.empty?

      result = remote_exec("chcon #{flags.join(" ")} #{shell_single_quote(dest)}")
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "invalid selinux context: #{result[:stderr]}")
      end

      nil
    end

    # Combined attribute reconciliation for dest: mode/owner/group first
    # (#apply_file_attributes), then chattr flags, then the SELinux
    # context - the same order real Ansible's
    # set_fs_attributes_if_different applies them. Returns {changed,
    # failure}: failure a failed PluginResult when the chattr/chcon call
    # itself errored (both fail the task like real Ansible - neither is
    # silently swallowed the way a chmod/chown EPERM is).
    private def apply_extended_attributes(path : String) : {Bool, PluginResult?}
      changed = apply_file_attributes(path)

      attr_changed, failure = apply_attr(path)
      return {false, failure} if failure
      changed = true if attr_changed

      failure = apply_selinux_context(path)
      return {false, failure} if failure

      {changed, nil}
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::GetUrlPlugin.new(config)
plugin.run

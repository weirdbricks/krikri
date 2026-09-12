#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "base64"
require "system/user"
require "system/group"
require "../src/krikri/base_plugin"

module Krikri
  # uri plugin (ansible.builtin.uri) - makes an HTTP request (API calls,
  # health checks, webhooks). Native HTTP::Client, same rationale as
  # get_url.cr's own doc comment: this plugin binary already runs on
  # whichever host (local or remote) the task targets, so no remote_exec
  # fallback is needed.
  #
  # Real Ansible's own uri module does NOT support check mode at all - even
  # a plain GET is skipped outright under --check ("This action (uri) does
  # not support check mode.", verified against a real ansible-playbook
  # --check run, not assumed) - so this doesn't special-case GET/HEAD the
  # way an initial reading of the docs might suggest; every method skips.
  # `changed:` is always false, EXCEPT for the one stateful case real
  # Ansible's own module has: `dest:` file writing - and there, live-
  # verified against ansible-core 2.19.4 (see the dest: block below),
  # real Ansible reports `changed: true` on EVERY run with a writable
  # status, even when the response body is byte-identical to what's
  # already on disk (uri.py's write_file() skips the physical move on a
  # SHA1 match, but main() sets resp['changed'] = True unconditionally
  # right after it). The physical write itself is still skipped on
  # identical content, exactly like real Ansible's atomic_move-only-on-
  # checksum-mismatch.
  class UriPlugin < BasePlugin
    MAX_REDIRECTS = 10

    def execute : PluginResult
      url = @params["url"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: url") unless url

      # url_username:/url_password:'s documented aliases (user:/password:) -
      # real uri.py's argument_spec registers them, and its own EXAMPLES
      # use the short forms (the JIRA and Jenkins tasks pass user:/
      # password:). Blank resolves to unset, matching Python's truthiness
      # in _configure_auth's `if username:`.
      username = ["url_username", "user"].compact_map { |param_name| @params[param_name]? }.reject(&.empty?).first?
      password = ["url_password", "password"].compact_map { |param_name| @params[param_name]? }.reject(&.empty?).first? || ""

      # src: and body: are mutually exclusive (real uri.py's
      # mutually_exclusive=[['body', 'src']]; failure text live-verified
      # against ansible-core 2.19.4).
      if @params["src"]? && @params["body"]?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: body|src")
      end

      # POST body from a file (real uri.py: `data = open(src, 'rb')`).
      # The plugin binary runs on the target host, so this reads the
      # plugin-host filesystem - identical to remote_src: true. The
      # remote_src: false controller-file-staging half (real Ansible
      # uploads the controller file for you) is NOT implemented - for
      # ansible_connection=local (the overwhelmingly common uri+src
      # case: posting a rendered payload) controller and target are the
      # same machine and it's exact.
      src_body = nil
      if src = @params["src"]?
        begin
          src_body = File.read(expand_tilde(src))
        rescue ex : File::Error
          return PluginResult.new(changed: false, failed: true, msg: "Unable to open source file #{src}", url: url, status: -1, elapsed: 0, redirected: false)
        end
      end

      if true?(@params["check_mode"]?)
        return PluginResult.new(changed: false, failed: false, msg: "Skipped: uri module does not support check mode", skipped: true)
      end

      method = (@params["method"]? || "GET").upcase
      # Real uri.py validates the method AFTER uppercasing (`method =
      # module.params['method'].upper()` then `^[A-Z]+$`), so "get" is
      # accepted but a multi-word or non-alpha method fails outright.
      unless method.matches?(/\A[A-Z]+\z/)
        return PluginResult.new(changed: false, failed: true, msg: "Parameter 'method' needs to be a single word in uppercase, like GET or POST.")
      end

      status_codes = (@params["status_code"]? || "200").split(",").map(&.strip.to_i)

      # creates:/removes: idempotency short-circuit, same semantics as
      # command's (exist → skip / not-exist → skip). Real uri.py exits
      # with a stdout (not msg!) field - live-verified result shape:
      # {changed: false, stdout: "skipped, since '/etc/hostname' exists",
      # stdout_lines: [...]}. The same text is also carried in msg here
      # (PluginResult always emits one) but roles read `stdout`.
      if creates = @params["creates"]?
        creates_path = expand_tilde(creates)
        if File.exists?(creates_path)
          skip_text = "skipped, since '#{creates_path}' exists"
          return PluginResult.new(changed: false, failed: false, msg: skip_text, stdout: skip_text, stdout_lines: [skip_text])
        end
      end
      if removes = @params["removes"]?
        removes_path = expand_tilde(removes)
        unless File.exists?(removes_path)
          skip_text = "skipped, since '#{removes_path}' does not exist"
          return PluginResult.new(changed: false, failed: false, msg: skip_text, stdout: skip_text, stdout_lines: [skip_text])
        end
      end

      start = Time.monotonic
      begin
        status, headers, body, redirected, final_url, reason = request(url, method, username, password, src_body)
      rescue ex
        # Real Ansible's uri result ALWAYS carries a status field, even when
        # the request dies before any HTTP response: its fetch_url() info
        # dict is initialized with status=-1 and stays there on connection
        # failures (refused/DNS/timeout). Omitting it here turned a role's
        # `when: r.status == 200` into a hard "object has no attribute
        # 'status'" evaluation error instead of a normal skip
        # (levonet.ci_registry_rm_container divergence).
        return PluginResult.new(changed: false, failed: true, msg: "Request failed: #{ex.message}", url: url, status: -1, elapsed: 0, redirected: false)
      end
      elapsed = (Time.monotonic - start).total_seconds.to_i

      failed = !status_codes.includes?(status)
      # Real failure msgs carry urllib's own HTTPError string as a suffix
      # (fetch_url catches the HTTPError and stuffs str(e) into info['msg'],
      # and uri.py formats 'Status code was %s and not %s: %s') -
      # live-verified: "Status code was 404 and not [200]: HTTP Error 404:
      # Not Found". urllib raises HTTPError only for 4xx/5xx, so other
      # out-of-list statuses (e.g. a 302 with follow_redirects: none) keep
      # the bare msg.
      msg = if failed
              status >= 400 ? "Status code was #{status} and not #{status_codes}: HTTP Error #{status}: #{http_reason(status, reason)}" : "Status code was #{status} and not #{status_codes}"
            else
              "OK (#{body.bytesize} bytes)"
            end

      changed = false
      result = PluginResult.new(changed: changed, failed: failed, msg: msg, url: final_url, status: status)

      if dest_param = @params["dest"]?
        dest = expand_tilde(dest_param)
        # dest: pointing at a DIRECTORY lands the file under a name taken
        # from Content-Disposition's filename param, then the URL's own
        # basename, then "index.html" (real uri.py's get_response_filename
        # fallback chain; live-verified the Content-Disposition leg). Note
        # `path:` in the result is set even when nothing was written.
        dest = File.join(dest, response_filename(headers, final_url)) if Dir.exists?(dest)
        if !failed && status != 304
          # Live-verified against ansible-core 2.19.4: changed: true on
          # EVERY dest: run with a success status, even when the file
          # already holds identical content (uri.py sets resp['changed']
          # = True unconditionally after write_file, whose SHA1 check
          # only gates the physical move). The old behavior here -
          # changed: false on identical content - was a guessed
          # "idempotency fix" that actually diverged.
          write_dest(dest, body)
          result.changed = true
          apply_file_attributes(dest)
          apply_dest_file_keys(result, dest)
        end
        result.extra["path"] = JSON::Any.new(dest)
      end

      result.extra["elapsed"] = JSON::Any.new(elapsed)
      apply_response_extras(result, headers, body, redirected)
      result
    end

    # Writes the response body to `dest:` unless the file already
    # contains identical content - mirrors real Ansible's own uri
    # module (a SHA1 comparison gates only the physical atomic_move,
    # not the reported `changed:` - see the dest: block in #execute for
    # the live-verified semantics).
    private def write_dest(dest : String, body : String) : Bool
      return false if File.exists?(dest) && File.read(dest) == body

      File.write(dest, body)
      true
    end

    private def apply_response_extras(result : PluginResult, headers : HTTP::Headers, body : String, redirected : Bool) : Nil
      content_type = headers["Content-Type"]?.try(&.split(";").first.strip) || ""
      result.extra["content_type"] = JSON::Any.new(content_type)
      result.extra["redirected"] = JSON::Any.new(redirected)

      # Real Ansible's uri module merges EVERY response header into the
      # result, transmogrified the way its own comment puts it: "replacing
      # '-' with '_', since variables don't work with dashes" and
      # lowercased ("headers are title cased. Lowercase them to be
      # compatible with the python2 behaviour") - `ukey = key.replace("-",
      # "_").lower()`. So `Content-Disposition` is exposed as
      # `content_disposition`, `X-Frame-Options` as `x_frame_options`,
      # etc., and a role may read `head_query.content_disposition`
      # directly (gantsign.postman does exactly this to resolve the
      # "latest" download filename from a HEAD request - previously
      # missing here, the read hit "'head_query.content_disposition' is
      # undefined" and failed the task where real Ansible rc=0'd).
      # Core keys (status/url/changed/...) can't be clobbered by a header
      # name - none of them contain a dash - and content_type/location
      # keep their existing, already-correct values below.
      headers.each do |name, values|
        ukey = name.gsub("-", "_").downcase
        # python's dict-comprehension merge keeps the LAST duplicate header
        result.extra[ukey] = JSON::Any.new(values.last)
      end

      # Real Ansible urljoin()s location against the request URL; this
      # engine keeps the raw header value (pre-existing behavior).
      if location = headers["Location"]?
        result.extra["location"] = JSON::Any.new(location)
      end

      if true?(@params["return_content"]?) || content_type == "application/json"
        result.extra["content"] = JSON::Any.new(body)
      end

      if content_type == "application/json"
        begin
          result.extra["json"] = JSON.parse(body)
        rescue
        end
      end
    end

    # Returns the FINAL (post-redirect) URL as its 5th element - real
    # Ansible's own `uri:` result `url` field is this final URL, not the
    # originally-requested one (verified live against ansible-core
    # 2.19.12: `uri: {url: .../releases/latest}`'s own result.url comes
    # back as `.../releases/tag/2.42.0`, the actual GitHub redirect
    # target). Found via tigattack.mergerfs's own idiom -
    # `mergerfs_github_release_page['url'].split('/')[-1]` to extract
    # the real version tag from the redirect target - which this
    # engine's own previous behavior (always returning the ORIGINAL
    # request url unchanged) broke silently: `.split('/')[-1]` on the
    # literal "releases/latest" URL gave the string "latest" instead of
    # a real version, producing a download URL that 404'd. The 6th
    # element is the response's reason phrase (real failure msgs embed
    # it, see #execute).
    private def request(url : String, method : String, username : String? = nil, password : String = "", src_body : String? = nil, redirects_left : Int32 = MAX_REDIRECTS, redirected : Bool = false) : {Int32, HTTP::Headers, String, Bool, String, String}
      raise "too many redirects" if redirects_left < 0

      uri = URI.parse(url)
      client = build_client(uri)
      headers, body = request_headers_and_body(src_body, redirected)

      # Basic auth. force_basic_auth: true sends the Authorization header
      # on the FIRST request (real urls.py's basic_auth_header branch);
      # the DEFAULT (false) is real Ansible's two-step flow: an
      # unauthenticated first request, then - only on a 401 challenge -
      # one retry WITH the header (urllib's HTTPBasicAuthHandler). The
      # Digest half of real Ansible's handler pair is deferred, so a
      # Digest-only endpoint gets our Basic attempt rejected instead of
      # a proper MD5 response.
      forced = true?(@params["force_basic_auth"]?)
      if username && forced
        headers["Authorization"] = basic_auth_header(username, password)
      end

      response = client.exec(method, uri.request_target, headers: headers, body: body)

      if username && !forced && response.status_code == 401
        auth_headers = headers.dup
        auth_headers["Authorization"] = basic_auth_header(username, password)
        response = client.exec(method, uri.request_target, headers: auth_headers, body: body)
      end

      if response.status.redirection? && (location = response.headers["Location"]?) && should_follow_redirect?(method)
        return request(resolve_redirect(uri, location), redirect_method(method, response.status_code), username, password, src_body, redirects_left - 1, true)
      end

      {response.status_code, response.headers, response.body, redirected, url, response.status_message || ""}
    ensure
      client.try(&.close)
    end

    private def basic_auth_header(username : String, password : String) : String
      "Basic " + Base64.strict_encode("#{username}:#{password}")
    end

    # Real failure msgs embed the reason phrase (urllib's "HTTP Error
    # 404: Not Found"); fall back to the status-code's own description
    # when the server sent a bare status line.
    private def http_reason(status : Int32, reason : String) : String
      reason.empty? ? (HTTP::Status.new(status).description || "") : reason
    end

    private def should_follow_redirect?(method : String) : Bool
      case @params["follow_redirects"]? || "safe"
      when "none", "no" then false
      when "safe"       then method == "GET" || method == "HEAD"
      else                   true
      end
    end

    # A 303 (or a 301/302 responding to POST) downgrades the redirected
    # request to GET, matching both real Ansible's underlying urllib
    # behavior and every browser's - a plain re-request of the same method
    # against a redirect target is not what a 303 means.
    private def redirect_method(method : String, status_code : Int32) : String
      (status_code == 303 || ((status_code == 301 || status_code == 302) && method == "POST")) ? "GET" : method
    end

    private def build_client(uri : URI) : HTTP::Client
      client = HTTP::Client.new(uri)

      timeout = (@params["timeout"]? || "30").to_i.seconds
      client.connect_timeout = timeout
      client.read_timeout = timeout

      if !true?(@params["validate_certs"]?, default: true) && (tls = client.tls?)
        tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end

      # TLS context customization. ca_path: replaces the system trust
      # store with the given PEM file (real uri.py passes ca_path into
      # the SSL context the same way). client_cert/client_key: client-
      # side certificate authentication - real uri.py's docs allow the
      # key to be bundled in the cert file, in which case client_key is
      # simply absent and OpenSSL reads both from the one file.
      if tls = client.tls?
        if ca_path = @params["ca_path"]?
          tls.ca_certificates = ca_path
        end
        if cert = @params["client_cert"]?
          tls.certificate_chain = cert
        end
        if key = @params["client_key"]?
          tls.private_key = key
        end
      end

      client
    end

    private def request_headers_and_body(src_body : String? = nil, redirected : Bool = false) : {HTTP::Headers, String?}
      headers = HTTP::Headers.new
      headers["User-Agent"] = @params["http_agent"]? || "ansible-httpget"

      # force: real urls.py's open() sends 'cache-control: no-cache' to
      # bypass any caching layer between here and the server.
      headers["Cache-Control"] = "no-cache" if true?(@params["force"]?)

      # decompress: false (real uri.py's decompress param, default true)
      # suppresses gzip at the REQUEST level: Crystal's HTTP::Client
      # otherwise always offers gzip/deflate and transparently inflates
      # the response, while real Ansible instead decides per-response
      # (decompress gates its GzipDecodedReader). Asking the server for
      # identity achieves the same observable result: the caller gets
      # exactly the bytes the server meant to send, undecoded. A user-
      # supplied Accept-Encoding wins, matching real header-override
      # order.
      if !true?(@params["decompress"]?, default: true) && !headers.has_key?("Accept-Encoding")
        headers["Accept-Encoding"] = "identity"
      end

      if headers_param = @params["headers"]?
        Hash(String, JSON::Any).from_json(headers_param).each { |key, value| headers[key] = value.to_s }
      end

      # Runs AFTER the user-headers merge so user-supplied headers are
      # subject to the filter too.
      if redirected
        unredirected_headers.each { |header_name| headers.delete(header_name) }
      end

      body = src_body || @params["body"]?
      body_format = @params["body_format"]? || "raw"

      case body_format
      when "json"
        headers["Content-Type"] = "application/json" unless headers.has_key?("Content-Type")
      when "form-urlencoded"
        headers["Content-Type"] = "application/x-www-form-urlencoded" unless headers.has_key?("Content-Type")
        body = form_encode(body) if body
      end

      {headers, body}
    end

    # `body:` for form-urlencoded arrives as a JSON object (a YAML dict is
    # JSON-encoded by the playbook parser before any plugin sees it) -
    # re-encoded here as real application/x-www-form-urlencoded pairs
    # rather than passed through as literal JSON text.
    private def form_encode(body : String) : String
      fields = Hash(String, JSON::Any).from_json(body)
      URI::Params.build { |form| fields.each { |key, value| form.add(key, value.to_s) } }
    rescue
      body
    end

    private def resolve_redirect(base : URI, location : String) : String
      URI.parse(location).absolute? ? location : base.resolve(location).to_s
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

    # Real uri.py's get_response_filename fallback chain for a
    # directory-shaped dest: (live-verified the Content-Disposition
    # leg): filename param (basename only), else the URL's unquoted
    # basename, else "index.html".
    private def response_filename(headers : HTTP::Headers, final_url : String) : String
      if disp = headers["Content-Disposition"]?
        if match = disp.match(/filename\s*=\s*"?([^";]+)"?/i)
          return File.basename(match[1])
        end
      end

      path = URI.parse(final_url).path
      base = path.rstrip("/")
      return "index.html" if base.empty?
      URI.decode(File.basename(base))
    rescue
      "index.html"
    end

    # The file-common result keys real Ansible's add_file_common_args
    # merge into every dest: result (live-verified shape: mode "0644"-
    # style zero-padded octal string, owner/group login names, uid/gid,
    # size, state "file").
    private def apply_dest_file_keys(result : PluginResult, dest : String) : Nil
      info = File.info?(dest)
      return unless info

      result.extra["path"] = JSON::Any.new(dest)
      result.extra["state"] = JSON::Any.new("file")
      result.extra["size"] = JSON::Any.new(info.size.to_i64)
      result.extra["mode"] = JSON::Any.new("0#{(info.permissions.value & 0o7777).to_s(8)}")
      result.extra["uid"] = JSON::Any.new(info.owner_id.to_i64)
      result.extra["gid"] = JSON::Any.new(info.group_id.to_i64)
      if owner = System::User.find_by?(id: info.owner_id.to_s)
        result.extra["owner"] = JSON::Any.new(owner.username)
      end
      if group = System::Group.find_by?(id: info.group_id.to_s)
        result.extra["group"] = JSON::Any.new(group.name)
      end
    end

    # dest:'s mode:/owner:/group: file-common args, mirroring
    # copy.cr's proven apply_file_attributes (octal-or-symbolic mode
    # split, native chown via System::User/Group lookups, best-effort
    # on permission failures). Attributes (chattr) and the SELinux
    # context params are accepted silently, like they are pre-pass.
    private def apply_file_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

      if mode = @params["mode"]?
        begin
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
      # fail the whole task - matches copy.cr/file.cr's own rescue.
      false
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::UriPlugin.new(config)
plugin.run

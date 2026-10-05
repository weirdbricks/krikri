#!/usr/bin/env crystal

require "json"
require "big"
require "http/client"
require "uri"
require "base64"
require "system/user"
require "system/group"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/url_preflight"
require "../src/krikri/plugin_helpers/socket_connect"

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
  #  `changed:` is always false, EXCEPT for the one stateful case real
  #  Ansible's own module has: `dest:` file writing - and there, live-
  #  verified against ansible-core 2.19.4 (see the dest: block below),
  #  real Ansible reports `changed: true` on EVERY 200 run with a writable
  #  status, even when the response body is byte-identical to what's
  #  already on disk (uri.py's write_file() skips the physical move on a
  #  SHA1 match, but main() sets resp['changed'] = True unconditionally
  #  right after it). The physical write itself is still skipped on
  #  identical content, exactly like real Ansible's atomic_move-only-on-
  #  checksum-mismatch.
  #
  #  The idempotency half of that story: when `dest:` already exists as a
  #  FILE (a directory dest gets no such header), real uri.py passes the
  #  file's mtime to fetch_url as last_mod_time, which becomes an
  #  `If-Modified-Since: <HTTP-date GMT>` request header (urls.py's
  #  rfc2822_date_string, live-verified). A 304 response then skips the
  #  write entirely and `changed:` stays false - so the warm run of a
  #  role fetching an unchanging file (claranet.postgresql's apt key,
  #  round 981032) reports `ok` in real Ansible, not `changed`. A 304
  #  reaches the module as urllib's HTTPError (urllib raises for every
  #  non-2xx it has no handler for), so the result msg carries urllib's
  #  "HTTP Error 304: Not Modified" string while the task itself still
  #  succeeds when 304 is in status_code. `force: true` replaces the
  #  header with `cache-control: no-cache` (urls.py's if/elif), and a
  #  user-supplied If-Modified-Since header wins over ours, matching
  #  urls.py's add_header ordering.
  class UriPlugin < BasePlugin
    # ansible.builtin.uri's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.uri). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[decompress force force_basic_auth remote_src return_content unsafe_writes use_gssapi
        use_netrc use_proxy validate_certs]
    end

    MAX_REDIRECTS = 10

    def execute : PluginResult
      validate_bool_params!
      url = @params["url"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: url") unless url

      # url_username:/url_password:'s documented aliases (user:/password:) -
      # real uri.py's argument_spec registers them, and its own EXAMPLES
      # use the short forms (the JIRA and Jenkins tasks pass user:/
      # password:). Blank resolves to unset, matching Python's truthiness
      # in _configure_auth's `if username:`.
      username = ["url_username", "user"].compact_map { |param_name| @params[param_name]? }.reject(&.empty?).first?
      password = ["url_password", "password"].compact_map { |param_name| @params[param_name]? }.reject(&.empty?).first? || ""

      # Real Ansible's uri ACTION plugin (its src: staging and its non-mapping
      # form-multipart body guard) runs before the module and therefore
      # before every check below - ArgspecValidator's action-level pass
      # is where those live, so they also fire ahead of the
      # mutually_exclusive validation here (live-verified: `src:`
      # pointing at a file the controller cannot see plus a `body:`
      # reports the controller-side "Could not find or access", while the
      # same pair with an EXISTING src reports "parameters are mutually
      # exclusive: body|src").

      # src: and body: are mutually exclusive (real uri.py's
      # mutually_exclusive=[['body', 'src']]; failure text live-verified
      # against ansible-core 2.19.4).
      if @params["src"]? && @params["body"]?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: body|src")
      end

      method = (@params["method"]? || "GET").upcase
      # Real uri.py validates the method AFTER uppercasing (`method =
      # module.params['method'].upper()` then `^[A-Z]+$`), so "get" is
      # accepted but a multi-word or non-alpha method fails outright.
      unless method.matches?(/\A[A-Z]+\z/)
        return PluginResult.new(changed: false, failed: true, msg: "Parameter 'method' needs to be a single word in uppercase, like GET or POST.")
      end

      # The module-side twin of the action plugin's guard (real uri.py's
      # own body_format == 'form-multipart' branch, running
      # prepare_multipart on the body): a non-mapping body fails HERE for
      # a remote_src: true task (which is the one shape the action plugin
      # skips), before creates:/removes: are even looked at -
      # live-verified, a task whose removes: file does not exist (which
      # would otherwise skip with ok) fails on the body instead. Note this
      # check is NOT limited to remote_src: true: a remote_src: false
      # task with a non-mapping body fails here only if the action plugin
      # did not already reject it (e.g. under a check-mode skip, which
      # raises before the module runs at all).
      if body_format? == "form-multipart"
        if type_name = non_mapping_body_type_name
          return PluginResult.new(changed: false, failed: true,
            msg: "failed to parse body as form-multipart: Mapping is required, cannot be type #{type_name}")
        end
      end

      status_codes = (@params["status_code"]? || "200").split(",").map { |part| decimal_int(part.strip) }

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

      # POST body from a file (real uri.py: `data = open(src, 'rb')`),
      # read INSIDE its uri() helper - i.e. after the creates:/removes:
      # short-circuits above (live-verified: a remote_src: true task whose
      # creates: file exists skips with ok without ever reporting the
      # missing src). The plugin binary runs on the target host, so this
      # reads the plugin-host filesystem - identical to remote_src: true.
      # Real's failure here is its own fail_json with elapsed and NOTHING
      # else: no url, no status, no redirected.
      src_body = nil
      if src = @params["src"]?
        begin
          src_body = File.read(expand_tilde(src))
        rescue IO::Error
          # IO::Error, not File::Error: a src: that is a DIRECTORY raises
          # the plain IO::Error (File::Error is its SUBCLASS, so the
          # narrower rescue never caught it and the plugin crashed with
          # "Plugin execution failed: read (...): Is a directory") -
          # real fails the task with exactly this msg instead
          # (live-verified vs 2.19.11: a remote_src: true task with a
          # directory src).
          return PluginResult.new(changed: false, failed: true, msg: "Unable to open source file #{src}", elapsed: 0)
        end
      end

      if true?(@params["_ansible_check_mode"]?)
        # Real's registered uri check-mode skip runs skipped, msg, changed
        # (live-verified vs 2.19.11 via `{{ r | to_json }}`).
        return PluginResult.new(changed: false, failed: false, msg: "Skipped: uri module does not support check mode", skipped: true,
          key_order: ["skipped", "msg", "changed"])
      end

      start = Time.instant
      # Cookies accumulate across the whole redirect chain (real's
      # HTTPCookieProcessor feeds every hop's response into one jar),
      # collected in response order - see #response_cookies.
      cookie_acc = [] of {String, String}
      # Real uri.py: when dest is already a regular FILE (checked on the
      # ORIGINAL dest, before any directory-filename resolution), the
      # file's mtime goes to fetch_url as last_mod_time and comes out as
      # an If-Modified-Since header; a 304 then leaves the file alone
      # and changed: stays false. A directory dest gets no header.
      last_mod_time = nil
      if dest_param = @params["dest"]?
        dest_path = expand_tilde(dest_param)
        last_mod_time = File.info(dest_path).modification_time if File.file?(dest_path)
      end
      # Real Ansible's fetch_url builds the SSL context and resolves the
      # gssapi handler BEFORE urllib parses the URL, so a bad ciphers:
      # list, an unusable ca_path:/client_cert:/client_key: or
      # use_gssapi: on a host without python-gssapi fails before any
      # request - and only a request that survives all of it can reach
      # urllib's scheme-less-URL ValueError ("unknown url type: '<url>'",
      # live-verified vs 2.19.11 message and result keys: no
      # elapsed/redirected/content). It sits here, after the
      # creates:/removes: short-circuits (a task whose creates: file
      # exists skips with ok whatever its URL or ciphers say -
      # live-verified) and after the src: read.
      if failure = PluginHelpers::URLPreflight.check(
           url,
           ciphers: tls_ciphers,
           ca_path: @params["ca_path"]?,
           client_cert: @params["client_cert"]?,
           client_key: @params["client_key"]?,
           use_gssapi: true?(@params["use_gssapi"]?, default: false),
         )
        return preflight_failure_result(failure, url, status_codes)
      end
      begin
        status, headers, body, redirected, final_url, reason = request(url, method, username, password, src_body, last_mod_time: last_mod_time, cookie_acc: cookie_acc)
      rescue ex
        # A scheme real's urllib has no handler for never reaches uri.py's
        # resp assembly - urlopen raises URLError("unknown url type: X")
        # and fetch_url turns it into the status -1 shape. Schemes urllib
        # DOES open (file:, data:) hit the opposite wall: the response
        # carries no HTTP status, so uri.py's `resp['status'] =
        # int(resp['status'])` crashes the module with int()'s own
        # TypeError text (live-verified vs 2.19.11 for file:///etc/hostname -
        # the registered result is exactly {failed, changed, exception, msg}
        # with that message, and no url/status/elapsed/redirected at all).
        # ftp(s) keeps its krikri-side failure: real would attempt the FTP
        # protocol itself, which this engine does not implement.
        scheme = begin
          URI.parse(url).scheme.try(&.downcase) || ""
        rescue
          ""
        end
        case scheme
        when "file", "data"
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Task failed: Module failed: int() argument must be a string, a bytes-like object or a real number, not 'NoneType'",
            key_order: ["failed", "changed", "exception", "msg"],
          )
        when "http", "https", "ftp"
          # fall through to the ordinary failure shapes below
        else
          return failed_request_result(
            "Status code was -1 and not #{status_codes}: Request failed: <urlopen error unknown url type: #{scheme}>", url, start)
        end
        # Real Ansible's uri result ALWAYS carries a status field, even when
        # the request dies before any HTTP response: its fetch_url() info
        # dict is initialized with status=-1 and stays there on connection
        # failures (refused/DNS/timeout). Omitting it here turned a role's
        # `when: r.status == 200` into a hard "object has no attribute
        # 'status'" evaluation error instead of a normal skip
        # (levonet.ci_registry_rm_container divergence).
        # The same failed result carries content: "" - real uri.py merges
        # fetch_url's body ('' when there was no response) into resp before
        # fail_json - but ONLY when return_content asked for it (uri.py's
        # own fail_json(content=u_content, **uresp) vs fail_json(**uresp)),
        # live-verified against ansible-core 2.19: a return_content: false
        # connection-refused result is {"status": -1, "elapsed": 0,
        # "msg": "Status code was -1 and not [200]: Request failed: ...",
        # "redirected": false} with no content key, and the
        # return_content: true one adds "content": "" (a role's
        # failed_when reading the registered result's .content,
        # geerlingguy.node_exporter's "'Metrics' not in
        # metrics_output.content", round 970310, needs exactly that).
        # What follows "Request failed: " is urllib's own wording: a refused
        # connect reads "<urlopen error [Errno 111] Connection refused>"
        # (live-verified against ansible-core 2.19.11), which `request` has
        # already rebuilt from a re-probe - Crystal's connect reports the
        # wrong errno for it.
        return failed_request_result(
          "Status code was -1 and not #{status_codes}: Request failed: #{ex.message}", url, start)
      end
      elapsed = (Time.instant - start).total_seconds.to_i

      failed = !status_codes.includes?(status)
      # Real failure msgs carry urllib's own HTTPError string as a suffix
      # (fetch_url catches the HTTPError and stuffs str(e) into info['msg'],
      # and uri.py formats 'Status code was %s and not %s: %s') -
      # live-verified: "Status code was 404 and not [200]: HTTP Error 404:
      # Not Found". urllib raises HTTPError for every status it has no
      # handler for - not just 4xx/5xx but also a 304 (no handler exists
      # for it), live-verified: a 304-in-status_code run succeeds with msg
      # "HTTP Error 304: Not Modified", and a 304 NOT in status_code fails
      # with "Status code was 304 and not [200]: HTTP Error 304: Not
      # Modified". Other out-of-list statuses (e.g. a 302 with
      # follow_redirects: none) keep the bare msg.
      msg = if failed
              status >= 400 || status == 304 ? "Status code was #{status} and not #{status_codes}: HTTP Error #{status}: #{http_reason(status, reason)}" : "Status code was #{status} and not #{status_codes}"
            elsif status == 304
              "HTTP Error #{status}: #{http_reason(status, reason)}"
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
          # EVERY 200 dest: run, even when the file already holds
          # identical content (uri.py sets resp['changed'] = True
          # unconditionally after write_file, whose SHA1 check only
          # gates the physical move). The 304 leg (no write at all,
          # changed: stays false) is what makes the warm rerun of a
          # dest: fetch idempotent - that header comes from the
          # last_mod_time computed before the request above.
          write_dest(dest, body)
          result.changed = true
          apply_file_attributes(dest)
        end
        result.extra["path"] = JSON::Any.new(dest)
        # Real AnsibleModule._return_formatted's add_path_info: ANY
        # result carrying a path: whose file exists gets the file-common
        # stat keys merged in - including a 304 run (nothing was written
        # but the dest file exists) and a failed run over an existing
        # dest. Live-verified: the 304 result carries owner/group/mode/
        # size/state/uid/gid exactly like the 200 one.
        apply_dest_file_keys(result, dest)
      end

      result.extra["elapsed"] = JSON::Any.new(elapsed)
      apply_response_extras(result, headers, body, redirected)
      # Real fetch_url parses the cookie jar into
      # the result on every response urllib returns normally: cookies
      # (name -> value dict) and cookies_string ("name=value; name2=value2"),
      # both ALWAYS present - empty dict/"" when no Set-Cookie came back.
      # Live-verified against ansible-core 2.19.11: values are kept raw
      # (a quoted value stays quoted in both keys), response order is
      # kept, and the two keys land between the transmogrified response
      # headers and msg. The HTTPError leg of fetch_url (any status
      # urllib raises for: 4xx/5xx and 304) never populates the jar
      # keys, so a failed or 304 result carries neither - hence the
      # status guard (a sub-400 status NOT in status_code still gets
      # them, exactly like real's fail_json(**uresp) path).
      if status < 400 && status != 304
        cookie_dict = {} of String => JSON::Any
        cookie_acc.each { |(name, value)| cookie_dict[name] = JSON::Any.new(value) }
        result.extra["cookies_string"] = JSON::Any.new(cookie_dict.map { |name, value| "#{name}=#{value}" }.join("; "))
        result.extra["cookies"] = JSON::Any.new(cookie_dict)
      end
      # Real's registered uri success order (live-verified vs 2.19.11 via
      # `{{ r | to_json }}`): content (only with return_content -
      # exit_json's leading kwarg), redirected, url, status, then EVERY
      # response header transmogrified in response order, then msg,
      # elapsed, changed, path (dest:), json (json body - appended after
      # path by uresp), then add_path_info's stat block. The response
      # headers vary per server, so the order list is built per request;
      # failure results (status not in status_code) keep the historical
      # order - real's fail_json shape was not pinned here.
      unless failed
        order = [] of String
        order << "content" if result.extra.has_key?("content")
        order += ["redirected", "url", "status"]
        headers.each { |name, _| order << name.gsub("-", "_").downcase }
        order << "cookies_string" if result.extra.has_key?("cookies_string")
        order << "cookies" if result.extra.has_key?("cookies")
        order += ["msg", "elapsed", "changed"]
        order << "path" if result.extra.has_key?("path")
        order << "json" if result.extra.has_key?("json")
        order += ["uid", "gid", "owner", "group", "mode", "state", "size"]
        result.key_order = order
      end
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
    private def request(url : String, method : String, username : String? = nil, password : String = "", src_body : String? = nil, redirects_left : Int32 = MAX_REDIRECTS, redirected : Bool = false, last_mod_time : Time? = nil, cookie_acc : Array(Tuple(String, String))? = nil) : {Int32, HTTP::Headers, String, Bool, String, String}
      raise "too many redirects" if redirects_left < 0

      uri = URI.parse(url)
      client = build_client(uri)
      headers, body = request_headers_and_body(src_body, redirected, last_mod_time)

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

      response = begin
        first = client.exec(method, uri.request_target, headers: headers, body: body)

        if username && !forced && first.status_code == 401
          auth_headers = headers.dup
          auth_headers["Authorization"] = basic_auth_header(username, password)
          client.exec(method, uri.request_target, headers: auth_headers, body: body)
        else
          first
        end
      rescue ex : Socket::ConnectError
        # this hop is the one that failed, so its URL is the one to re-probe
        raise Exception.new(PluginHelpers::SocketConnect.urlopen_error_text(uri, ex) || ex.message)
      end

      cookie_acc.try(&.concat(response_cookies(response.headers)))

      if response.status.redirection? && (location = response.headers["Location"]?) && should_follow_redirect?(method)
        return request(resolve_redirect(uri, location), redirect_method(method, response.status_code), username, password, src_body, redirects_left - 1, true, last_mod_time, cookie_acc)
      end

      {response.status_code, response.headers, response.body, redirected, url, response.status_message || ""}
    ensure
      client.try(&.close)
    end

    # The name/value pairs of every Set-Cookie header of one response, in
    # header order - the cookie text before the first ';' is "name=value".
    # Values are kept byte-raw like real's cookiejar (a quoted value stays
    # quoted in both cookies and cookies_string, live-verified vs 2.19.11);
    # header lines without a '=' (or an empty name) are skipped.
    private def response_cookies(headers : HTTP::Headers) : Array(Tuple(String, String))
      cookie_values = [] of String
      headers.each do |name, values|
        cookie_values.concat(values) if name.downcase == "set-cookie"
      end
      cookie_values.compact_map do |header_value|
        pair = header_value.split(';', 2)[0]
        eq = pair.index('=')
        next if eq.nil? || eq == 0
        name = pair[0...eq].strip
        next if name.empty?
        {name, pair[(eq + 1)..].strip}
      end
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

    # Real's check_type_int conversion (Decimal(value), integral required):
    # a spec-valid int-typed option that is not a plain integer spelling
    # ("1.0") still converts to its truncated int instead of crashing the
    # plugin's own strict parse. A YAML boolean member demotes to
    # "true"/"false" wire text and real keeps it a Python bool - an int
    # subclass (True == 1) - so it converts too.
    private def decimal_int(raw : String) : Int32
      return 1 if raw == "true"
      return 0 if raw == "false"
      BigDecimal.new(raw).to_i
    rescue
      raw.to_i
    end

    # Real uri.py's three pre-request failures (see URLPreflight) reach
    # the task with two different shapes, live-verified against
    # ansible-core 2.19.11:
    #
    #   * MissingLibrary - fetch_url's `except MissingModuleError` handler
    #     is a bare fail_json(msg=...): {changed: false, msg} alone, no
    #     url/status/elapsed.
    #   * UnknownUrlType - the ValueError from urllib's Request(url),
    #     re-raised the same way with info = {url, status: -1}.
    #   * ConnectionFailure - the OSError became info['msg'] with
    #     status -1, so the request DID run uri.py's own
    #     "Status code was %s and not %s: %s" formatting, on top of the
    #     redirected/elapsed/changed keys its resp always carries.
    private def preflight_failure_result(failure : PluginHelpers::URLPreflight::Failure, url : String, status_codes : Array(Int32)) : PluginResult
      case failure.kind
      when PluginHelpers::URLPreflight::Kind::MissingLibrary
        PluginResult.new(changed: false, failed: true, msg: failure.msg)
      when PluginHelpers::URLPreflight::Kind::UnknownUrlType
        PluginResult.new(changed: false, failed: true, msg: failure.msg, url: url, status: -1)
      else
        failed_request_result("Status code was -1 and not #{status_codes}: #{failure.msg}", url)
      end
    end

    # A uri failure that went through uri.py's own resp assembly (a
    # request that ran and came back with status -1): status, url,
    # redirected: false, elapsed: 0, plus content: "" when return_content
    # asked for the body.
    #
    # Key order is real's fail_json kwargs order (live-verified vs
    # 2.19.11 via `{{ r | to_json }}` on a connection-refused failure):
    # redirected, url, status, elapsed, changed, failed, msg, exception.
    # msg/failed/exception are the executor/backfill keys to_json adds -
    # real's fail_json binds msg to its named parameter (moving it after
    # the failed flag it appends) and _return_formatted trails exception
    # last. With return_content: true real calls
    # fail_json(content=..., **uresp), so content leads the whole dict.
    private def failed_request_result(msg : String, url : String, start : Time::Instant? = nil) : PluginResult
      elapsed = start ? (Time.instant - start).total_seconds.to_i : 0
      result = PluginResult.new(changed: false, failed: true, msg: msg, url: url, status: -1, elapsed: elapsed, redirected: false)
      order = [] of String
      order << "content" if true?(@params["return_content"]?)
      order += ["redirected", "url", "status", "elapsed", "changed", "failed", "msg", "exception"]
      result.key_order = order
      result.extra["content"] = JSON::Any.new("") if true?(@params["return_content"]?)
      result
    end

    # ciphers: real uri types it as a LIST of cipher names joined with ":"
    # (module doc: "all ciphers are joined in order with C(:)"). The param
    # arrives here as its JSON text (["TLS_AES_256_GCM_SHA384",...]); a
    # plain string passes through untouched.
    private def tls_ciphers : String?
      raw = @params["ciphers"]? || return nil
      begin
        list = Array(String).from_json(raw)
        list.empty? ? nil : list.join(":")
      rescue
        raw
      end
    end

    private def body_format? : String
      (@params["body_format"]? || "raw").downcase
    end

    # The Python type name real Ansible puts in its "cannot be type X"
    # multipart messages, or nil when body: IS a mapping (the only shape
    # that gets past the check). Live-verified against ansible-core
    # 2.19.11 for NoneType/bool/str/int/float/list - the UNTAGGED
    # wording, since the module receives the task args untouched (the
    # action plugin's _AnsibleTagged* wording lives in
    # ArgspecValidator, which is where that check runs).
    #
    # Known residue: a string body whose own text happens to be valid JSON
    # (`body: "5"`) reaches a plugin indistinguishable from the number 5.
    private def non_mapping_body_type_name : String?
      # A marked non-string YAML literal keeps its native type through
      # BasePlugin (non_string_param / non_string_member_list), which is
      # what decides bool/int/float/list here.
      if native = non_string_param("body")
        return python_type_name(native.raw)
      end
      return "list" if non_string_member_list("body")

      raw = @params["body"]?
      return "NoneType" unless raw

      parsed = begin
        JSON.parse(raw).raw
      rescue
        nil
      end
      return "str" if parsed.nil?
      python_type_name(parsed)
    end

    # Python class name for a JSON-decoded value. A JSON object is a
    # Mapping - the one shape that gets past the check - and falls out of
    # the case as this method's nil.
    private def python_type_name(value : JSON::Any::Type) : String?
      case value
      when Bool    then "bool"
      when Int64   then "int"
      when Float64 then "float"
      when String  then "str"
      when Array   then "list"
      end
    end

    private def build_client(uri : URI) : HTTP::Client
      client = HTTP::Client.new(uri)

      timeout = decimal_int((@params["timeout"]? || "30")).seconds
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
      # ciphers: the OpenSSL cipher-list string, joined from the LIST
      # param exactly as real uri.py hands it to make_context.
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
        if ciphers = tls_ciphers
          tls.ciphers = ciphers
        end
      end

      client
    end

    private def request_headers_and_body(src_body : String? = nil, redirected : Bool = false, last_mod_time : Time? = nil) : {HTTP::Headers, String?}
      headers = HTTP::Headers.new
      headers["User-Agent"] = @params["http_agent"]? || "ansible-httpget"

      # force: real urls.py's open() sends 'cache-control: no-cache' to
      # bypass any caching layer between here and the server.
      headers["Cache-Control"] = "no-cache" if true?(@params["force"]?)

      # last_mod_time -> If-Modified-Since: real urls.py's if/elif -
      # force: takes the cache-control branch and no conditional-get
      # header is sent; otherwise the dest file's mtime formatted as an
      # HTTP-date in GMT (urls.py's rfc2822_date_string(timetuple,
      # 'GMT'), e.g. "Fri, 09 Nov 2001 01:08:47 GMT"). Set BEFORE the
      # user-headers merge below so a user-supplied If-Modified-Since
      # wins, matching urls.py's add_header ordering.
      if last_mod_time && !true?(@params["force"]?) && !headers.has_key?("If-Modified-Since")
        headers["If-Modified-Since"] = Time::Format::HTTP_DATE.format(last_mod_time)
      end

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
        rescue File::Error
          # Mode setting failed, continue anyway
        end
      end

      uid = -1
      gid = -1

      # A present owner:/group: value (explicit empty string included)
      # is always resolved - and an unresolvable name fails the task
      # like real Ansible's basic.py (round900811 kilip.chezmoi) -
      # instead of the old `&&`-short-circuit that silently skipped the
      # chown whenever the lookup came back empty.
      if owner = @params["owner"]?
        uid = resolve_owner_uid(owner)
      end

      if group = @params["group"]?
        gid = resolve_group_gid(group)
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue File::Error
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

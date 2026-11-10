require "http/client"
require "uri"
require "base64"
require "./socket_connect"
require "./cookie_jar"

module Krikri
  module PluginHelpers
    # HTTPDownload - shared binary-safe HTTP download with redirect
    # following, used by get_url.cr and deb822_repository.cr. Both
    # plugins previously hand-rolled their own near-identical download
    # logic (each with its own redirect loop and body streaming); this
    # centralizes the common behavior so it can't drift apart (e.g. one
    # plugin learning redirect handling while the other doesn't).
    #
    # The download is binary-safe: response.body_io is streamed straight
    # to disk, matching how get_url.cr's own download always worked. A
    # plain HTTP::Client#get with a String-returning body would
    # UTF-8-decode and corrupt arbitrary binary data (GPG key bytes,
    # archives, etc.), so never "fix" this by reading into a String.
    module HTTPDownload
      DEFAULT_TIMEOUT       = 10.seconds
      DEFAULT_MAX_REDIRECTS = 5

      record Options,
        max_redirects : Int32 = DEFAULT_MAX_REDIRECTS,
        connect_timeout : Time::Span = DEFAULT_TIMEOUT,
        read_timeout : Time::Span = DEFAULT_TIMEOUT,
        headers : HTTP::Headers = HTTP::Headers.new,
        verify_tls : Bool = true,
        username : String? = nil,
        password : String? = nil,
        # Basic auth timing, mirroring Ansible's fetch_url: true sends
        # the Authorization header on the FIRST request; false (real
        # get_url/uri's default) holds it back until a 401 challenge, then
        # retries once WITH the header. The default here is true only to
        # preserve the pre-existing behavior of the helper's original
        # consumers; get_url passes the real param's default (false) through.
        force_basic_auth : Bool = true,
        client_cert : String? = nil,
        client_key : String? = nil,
        ciphers : String? = nil,
        unredirected_headers : Array(String) = [] of String,
        # Real fetch_url downloads through urllib's default ProxyHandler,
        # which routes each request through the http_proxy/https_proxy env
        # vars (no_proxy bypass included) of the module process - the very
        # env Ansible populates from the task's environment: keyword. The
        # caller picks the values out of its own env sources (task overlay
        # over ENV) since this helper never sees the task environment;
        # empty means "no proxy for that scheme", exactly like
        # getproxies_environment treats an unset var.
        http_proxy : String? = nil,
        https_proxy : String? = nil,
        no_proxy : String? = nil,
        # The request verb. Real fetch_url's `method` param: get_url only
        # ever sends GET or HEAD, and a --check run always HEADs ("From
        # Ansible 2.4 when run with --check, it will do a HEAD request to
        # validate the URL"), which is why its staged copy is empty.
        method : String = "GET",
        # Whether the target's urllib re-issues a redirected HEAD as a GET.
        # Only Python 3.13's HTTPRedirectHandler.redirect_request builds
        # the follow-up Request with the original method; every earlier
        # stdlib leaves method= unset there, so that Request defaults to
        # GET and downloads the whole body. get_url's --check exit compares
        # the staged body's sha1 against dest's, so the two behaviours
        # disagree about whether a converged dest is ok or changed (issue
        # #1101) - the caller asks the target's own interpreter.
        redirected_head_becomes_get : Bool = false

      # What the FINAL response of a redirect-following download looked
      # like: Ansible's get_url derives a directory-dest download's
      # filename from the final response's Content-Disposition header
      # (falling back to the FINAL post-redirect URL's basename), so
      # callers need both pieces of the last hop, not the original URL.
      record Result, final_url : String, headers : HTTP::Headers

      # A download that failed, carrying the pieces of Ansible's
      # fetch_url result dict the CALLING module needs to build its own
      # message around.
      #
      # fetch_url never raises for a failed request - it catches
      # everything and folds it into `info`:
      #
      #   * urllib.error.HTTPError  -> info['status'] = the code,
      #     info['msg'] = "HTTP Error <code>: <reason>"  (Kind::HttpError)
      #   * urllib.error.URLError   -> info['status'] = -1 (it has no
      #     code), info['msg'] = "Request failed: <urlopen error ...>"
      #     (Kind::UrlError)
      #   * OSError (incl. socket.timeout, which is what a connect or
      #     response-head timeout is on the socket layer) -> status -1,
      #     info['msg'] = "Connection failure: <str(ex)>"
      #     (Kind::ConnectionFailure)
      #
      # get_url's url_get then branches on that status alone: anything
      # that is not 200 or 304 fails with `response=info['msg']` plus a
      # status_code, everything at -1 fails with `msg=info['msg']` and
      # no status_code at all. Kind::ContentCopy is the one failure that
      # happens AFTER fetch_url returned (the staged write of the body
      # died), which get_url's own copyfileobj handler reports with
      # `failed to create temporary content file: <reason>` and elapsed
      # alone.
      class FetchError < Exception
        enum Kind
          UrlError
          ConnectionFailure
          HttpError
          ContentCopy
        end

        getter kind : Kind
        # fetch_url's own info['msg'] text, verbatim.
        getter info_msg : String
        # str() of the exception behind a ContentCopy failure.
        getter reason : String
        # The HTTP status, for Kind::HttpError only.
        getter status_code : Int32?

        def initialize(
          kind : Kind,
          info_msg : String,
          reason : String = "",
          status_code : Int32? = nil,
        )
          @kind = kind
          @info_msg = info_msg
          @reason = reason
          @status_code = status_code
          super(info_msg)
        end
      end

      # Downloads `url` to `dest`, following up to `max_redirects`
      # redirects and streaming the raw body byte-for-byte. Returns nil on
      # success; raises FetchError on a response other than 200 (including
      # 304, which Ansible's own url_get handles one branch higher up),
      # raises on too many redirects, and on an unsupported scheme.
      def self.download(
        url : String,
        dest : String,
        options : Options = Options.new,
      ) : Nil
        download_with_info(url, dest, options)
        nil
      end

      # Same as #download but returns the final hop's URL and response
      # headers (see Result).
      #
      # `auth_attempted` tracks the 401-challenge retry: with
      # force_basic_auth: false (the real-Ansible default) the first
      # request goes out WITHOUT Authorization and exactly one retry is
      # made WITH it when the server answers 401 - a second 401 then
      # surfaces as the failure it is instead of looping.
      def self.download_with_info(
        url : String,
        dest : String,
        options : Options = Options.new,
        redirects_left : Int32 = options.max_redirects,
        auth_attempted : Bool = false,
        cookie_jar : CookieJar? = nil,
      ) : Result
        raise "too many redirects" if redirects_left < 0
        # fetch_url creates a fresh jar per call (urls.py), so a nil jar
        # here is always the top-level entry; every hop reuses the one jar
        jar = cookie_jar || CookieJar.new

        uri = URI.parse(url)

        # http.client refuses a request target holding an ASCII control
        # character or a space (its _validate_path) BEFORE any network
        # I/O, and fetch_url's catch-all folds that InvalidURL into
        # info['msg']. URLs like this reach the download path from role
        # templating accidents (a newline inside a version pin, a space
        # in a path); without this gate Crystal's HTTP::Client answers
        # with its own ArgumentError verbatim, which reads nothing like
        # Ansible's message and names no offending character.
        reject_control_chars(uri.request_target)

        proxy = effective_proxy(uri, options)
        client, request_target, host_header = client_and_target(uri, options, proxy)
        headers = request_headers(options, auth_attempted)
        headers = with_jar_cookies(headers, uri, jar)
        headers = proxied_request_headers(headers, host_header, proxy)
        hop_response(client, uri, request_target, headers, url, dest, options, redirects_left, auth_attempted, jar)
      ensure
        client.try(&.close)
      end

      # Ansible's HTTPCookieProcessor adds the jar's matching cookies to
      # every request, redirect hops included; a user-supplied Cookie
      # header wins and the processor stays out (python's
      # add_cookie_header skips when the request already carries one).
      # Dup before adding: options.headers belongs to the caller and is
      # re-derived on every hop, where a different host needs different
      # cookies.
      private def self.with_jar_cookies(headers : HTTP::Headers, uri : URI, jar : CookieJar) : HTTP::Headers
        cookie_header = jar.cookie_header(uri)
        return headers if cookie_header.nil? || headers.has_key?("Cookie")

        headers = headers.dup
        headers["Cookie"] = cookie_header
        headers
      end

      # One hop's request and response handling, with fetch_url's
      # exception-to-failure-kind mapping around it.
      private def self.hop_response(
        client : HTTP::Client,
        uri : URI,
        request_target : String,
        headers : HTTP::Headers,
        url : String,
        dest : String,
        options : Options,
        redirects_left : Int32,
        auth_attempted : Bool,
        jar : CookieJar,
      ) : Result
        client.exec(options.method, request_target, headers: headers) do |response|
          # The processor harvests each response's Set-Cookie into the
          # one jar BEFORE the redirect/auth decisions, so the next
          # request - whichever branch takes it - already carries them.
          jar.store(uri, response.headers)

          if hop = redirect_hop(client, uri, response, url, dest, options, redirects_left, auth_attempted, jar)
            return hop
          end

          # Real url_get accepts ONLY 200: anything else (304 included -
          # Ansible handles that one a branch higher up, in url_get itself)
          # is urllib's HTTPError, whose str() is "HTTP Error <code>:
          # <reason>" with the reason phrase the SERVER sent.
          raise http_error(response) unless response.status_code == 200

          write_body(response, dest, uri.scheme.to_s)
          Result.new(final_url: url, headers: response.headers)
        end
      rescue ex : FetchError
        raise ex
      rescue ex : IO::TimeoutError
        raise timeout_failure(ex, uri.scheme.to_s)
      rescue Socket::Addrinfo::Error
        # getaddrinfo EAI_NONAME surfaces in urllib as socket.gaierror -2.
        raise FetchError.new(FetchError::Kind::UrlError, "Request failed: <urlopen error [Errno -2] Name or service not known>")
      rescue ex : Socket::ConnectError
        # real fetch_url's failure msg is urllib's own URLError text
        # ("Request failed: <urlopen error [Errno 111] Connection
        # refused>"); Crystal's connect reports the wrong errno for a
        # refused connect, so rebuild it from a re-probe (see
        # SocketConnect) and only fall back to Crystal's wording when
        # even that cannot name the error.
        text = SocketConnect.urlopen_error_text(uri, ex) ||
               "<urlopen error #{ex.message || ex.class.name}>"
        raise FetchError.new(FetchError::Kind::UrlError, "Request failed: #{text}")
      rescue ex : OpenSSL::SSL::Error
        # Every certificate rejection is a URLError carrying CPython's
        # ssl-module text in real Ansible
        # ("<urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate
        # verify failed: <reason> (_ssl.c:1147)>"), where Crystal only
        # has OpenSSL's own handshake error ("SSL_connect:
        # error:0A000086:SSL routines::certificate verify failed") -
        # which names neither the failure's cause nor Python's shape. The
        # trailing _ssl.c line number is CPython's own, so it is pinned to
        # the one the benchmark hosts run.
        reason = certificate_verify_reason(uri)
        if reason
          raise FetchError.new(FetchError::Kind::UrlError, "Request failed: <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: #{reason} (_ssl.c:1147)>")
        end
        raise ex
      end

      # Host names the ORIGIN, not the proxy hop the request travels over
      # - the client's own default would name the io socket's host (the
      # proxy). Returned as a copy, never mutated in place:
      # request_headers hands back the caller's own headers object, and a
      # redirect hop would otherwise inherit the previous origin's Host.
      # urllib's ProxyHandler also sends Proxy-Authorization on the
      # proxied request when the proxy URL itself carries credentials.
      private def self.proxied_request_headers(headers : HTTP::Headers, host_header : String, proxy : URI?) : HTTP::Headers
        return headers unless proxy

        headers = headers.dup
        headers["Host"] = host_header unless headers.has_key?("Host")
        if (user = proxy.user) && !user.empty?
          password = proxy.password || ""
          headers["Proxy-Authorization"] = "Basic #{Base64.strict_encode("#{user}:#{password}")}"
        end
        headers
      end

      # urllib's ProxyHandler request dispatch: pick the per-scheme proxy
      # setting, then drop it when the request host is bypassed via
      # no_proxy. Called per hop, so a redirect to another host is
      # re-evaluated exactly like urllib re-dispatches each redirect.
      private def self.effective_proxy(uri : URI, options : Options) : URI?
        return nil unless uri.host

        raw = case uri.scheme.to_s
              when "https" then options.https_proxy
              else              options.http_proxy
              end
        raw = raw.to_s.strip
        return nil if raw.empty?
        return nil if proxy_bypass?(uri.host, options.no_proxy)

        URI.parse(raw)
      end

      # urllib's proxy_bypass_environment: no_proxy is a comma-separated
      # host-suffix list, a bare '*' bypasses everything, and each entry
      # matches the request host as a suffix once its leading dots are
      # stripped (".example.com" and "example.com" both match
      # "host.example.com").
      private def self.proxy_bypass?(host : String?, no_proxy : String?) : Bool
        return false unless no_proxy && !no_proxy.strip.empty?

        entries = no_proxy.split(',')
        return true if entries.includes?("*")

        hostname = (host || "localhost").downcase
        entries.any? do |entry|
          entry = entry.strip.downcase.lstrip('.')
          !entry.empty? && hostname.ends_with?(entry)
        end
      end

      # The stdlib HTTP::Client has no proxy support, so the proxy hop is
      # hand-run here and the client is pointed at the socket this code
      # opened. A plain-http request goes to the proxy as an absolute-form
      # request target (RFC 7230 5.3.2); an https one is tunneled with
      # CONNECT and the client runs over the tunnel's TLS, SNI included.
      # The proxy connection itself is always plaintext, matching
      # urllib/http.client, which never TLS-wraps the proxy hop even when
      # the proxy URL says https:.
      private def self.client_and_target(uri : URI, options : Options, proxy : URI?) : Tuple(HTTP::Client, String, String)
        return build_client(uri, options), uri.request_target, "" unless proxy

        scheme_is_https = uri.scheme == "https"
        origin_host = uri.host || ""
        origin_port = uri.port || (scheme_is_https ? 443 : 80)
        proxy_host = proxy.host || ""
        proxy_port = proxy.port || 80

        socket = proxy_socket(proxy_host, proxy_port, options.connect_timeout)

        if scheme_is_https
          connect_tunnel(socket, origin_host, origin_port, proxy, options.read_timeout)
          # Same SNI + trailing-dot strip the stdlib client applies on its
          # own direct connect.
          io : IO = OpenSSL::SSL::Socket::Client.new(socket, context: tls_context(options), sync_close: true, hostname: origin_host.rchop('.'))
        else
          io = socket
        end
        socket.read_timeout = options.read_timeout
        socket.write_timeout = options.read_timeout

        # The host/port args only shape the Host header - the request goes
        # over the socket we opened, the header names the origin, with the
        # default port omitted the way the client's own host_header does.
        host_header = origin_port == (scheme_is_https ? 443 : 80) ? origin_host : "#{origin_host}:#{origin_port}"
        target = scheme_is_https ? uri.request_target : url_target(uri)
        {HTTP::Client.new(io, origin_host, origin_port), target, host_header}
      end

      # The TLS context a tunneled https request runs over, carrying the
      # same customization build_client applies on a direct connect.
      private def self.tls_context(options : Options) : OpenSSL::SSL::Context::Client
        tls = OpenSSL::SSL::Context::Client.new
        tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless options.verify_tls
        if cert = options.client_cert
          tls.certificate_chain = cert
        end
        if key = options.client_key
          tls.private_key = key
        end
        if ciphers = options.ciphers
          tls.ciphers = ciphers
        end
        tls
      end

      # The absolute-form request target a plain-http request needs when
      # the hop goes through a proxy.
      private def self.url_target(uri : URI) : String
        URI.new(uri.scheme, uri.host, uri.port, uri.request_target).to_s
      end

      # SocketConnect.open, not TCPSocket.new, for the same reason the
      # non-proxied path re-probes after a failure (see SocketConnect): a
      # refused proxy connect must carry the REAL errno so the URLError
      # text reads like Python's.
      private def self.proxy_socket(host : String, port : Int32, connect_timeout : Time::Span) : ::Socket
        SocketConnect.open(host, port, connect_timeout)
      rescue ex : Socket::Addrinfo::Error
        text = SocketConnect.urlopen_dns_error_text(ex) ||
               "<urlopen error #{ex.message || ex.class.name}>"
        raise FetchError.new(FetchError::Kind::UrlError, "Request failed: #{text}")
      rescue ex : Socket::ConnectError
        text = SocketConnect.urlopen_error_text(host, port, ex) ||
               "<urlopen error #{ex.message || ex.class.name}>"
        raise FetchError.new(FetchError::Kind::UrlError, "Request failed: #{text}")
      rescue IO::TimeoutError
        raise FetchError.new(FetchError::Kind::UrlError, "Request failed: <urlopen error timed out>")
      end

      # The HTTP CONNECT hop that turns the proxy connection into a tunnel
      # for https. On anything but a 200, python's http.client fails the
      # tunnel with "tunnel connection failed: <status line>" inside the
      # same URLError shape as any other proxy failure.
      private def self.connect_tunnel(socket : ::Socket, host : String, port : Int32, proxy : URI, timeout : Time::Span) : Nil
        request = String.build do |io|
          io << "CONNECT #{host}:#{port} HTTP/1.1\r\n"
          io << "Host: #{host}:#{port}\r\n"
          if (user = proxy.user) && !user.empty?
            password = proxy.password || ""
            io << "Proxy-Authorization: Basic #{Base64.strict_encode("#{user}:#{password}")}\r\n"
          end
          io << "\r\n"
        end
        socket.write_timeout = timeout
        socket.read_timeout = timeout
        socket.write(request.to_slice)

        head = read_connect_response_head(socket)
        parts = head.lines.first?.try(&.split) || [] of String
        unless parts.size >= 2 && parts[1] == "200"
          raise FetchError.new(FetchError::Kind::UrlError,
            "Request failed: <urlopen error tunnel connection failed: #{parts[1..].join(" ")}>")
        end
      rescue IO::TimeoutError
        raise FetchError.new(FetchError::Kind::UrlError, "Request failed: <urlopen error timed out>")
      end

      # Reads the CONNECT response head byte-wise up to its \r\n\r\n end,
      # so the TLS handshake that follows starts on clean response bytes.
      # A CONNECT head is tiny; the bound only stops a rogue proxy from
      # feeding bytes forever.
      private def self.read_connect_response_head(socket : ::Socket) : String
        head = IO::Memory.new
        buffer = Bytes.new(1)
        while head.size < 16_384
          got = socket.read(buffer)
          raise IO::EOFError.new("EOF while reading the CONNECT response") if got == 0
          head.write(buffer)
          break if head.to_s.ends_with?("\r\n\r\n")
        end
        head.to_s
      end

      # Real urllib words EVERY certificate rejection through CPython's ssl
      # module - "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
      # <reason> (_ssl.c:1147)" - where <reason> is libcrypto's own text for
      # the X509_V_ERR_* its store check landed on ("unable to get local
      # issuer certificate", "self-signed certificate", "certificate has
      # expired", ...), or, when the CHAIN verified and only the name is
      # wrong, CPython's own "Hostname mismatch, certificate is not valid for
      # '<host>'.". Crystal surfaces all of these as a bare OpenSSL handshake
      # error.
      #
      # urllib also sends SNI on every TLS request, so certificate-vhosting
      # servers (CDNs, shared hosts) answer it with the certificate the
      # requested hostname expects. This probe re-runs the handshake the way
      # urllib's does - SNI, chain verification, and only a post-handshake
      # hostname validation - so the caller can reproduce whichever reason
      # applies.
      #
      # OpenSSL::SSL::Socket::Client can't run this probe: its `hostname:`
      # argument sends SNI but also asks OpenSSL to verify the hostname in the
      # same handshake, failing on the very mismatch being decoded here. So the
      # probe drives LibSSL directly, exactly like Client#initialize but
      # without the X509_VERIFY_PARAM set1_host call.

      # The [\x00-\x20\x7f] scan byte-wise: these are all single-byte
      # ASCII codepoints, so UTF-8 continuation bytes (all >= 0x80) can
      # never false-positive, and a byte-level scan also survives a
      # target that is not valid UTF-8 at all.
      private def self.reject_control_chars(target : String) : Nil
        found = target.bytes.find { |byte| byte <= 0x20 || byte == 0x7f }
        return unless found
        raise FetchError.new(FetchError::Kind::UrlError,
          "An unknown error occurred: URL can't contain control characters. #{py_repr(target)} (found at least #{py_repr(found.chr.to_s)})")
      end

      # Python's repr() for the two quoted fragments in the
      # control-character message: single quotes unless the string itself
      # holds a ' but no " (repr picks the quote character that spares
      # itself an escape), a backslash before any literal backslash, \n,
      # \r and \t escaped by name, and every other codepoint below 0x20
      # plus 0x7f as a lowercase \xNN - which is how Python shows control
      # characters that have no short escape.
      private def self.py_repr(s : String) : String
        quote = s.includes?("'") && !s.includes?('"') ? '"' : '\''
        String.build do |io|
          io << quote
          s.each_char do |char|
            case char
            when '\\' then io << "\\\\"
            when '\n' then io << "\\n"
            when '\r' then io << "\\r"
            when '\t' then io << "\\t"
            else
              if char.ord < 0x20 || char.ord == 0x7f
                io << "\\x#{char.ord.to_s(16, precision: 2)}"
              elsif char == quote
                io << "\\" << char
              else
                io << char
              end
            end
          end
          io << quote
        end
      end

      # X509_V_OK: the store verified the chain, so a handshake that failed
      # anyway did so outside certificate verification - Crystal's own
      # wording is the honest one there.
      X509_V_OK = 0

      private def self.certificate_verify_reason(uri : URI) : String?
        host = uri.host
        return nil unless host

        context = OpenSSL::SSL::Context::Client.new
        ssl = LibSSL.ssl_new(context)
        return nil unless ssl

        tcp = TCPSocket.new(host, uri.port || 443)
        begin
          bio = OpenSSL::BIO.new(tcp)
          LibSSL.ssl_set_bio(ssl, bio.to_unsafe, bio.to_unsafe)
          # Without SNI the server may pick a different certificate, and the
          # chain check would then fail where urllib's succeeds.
          LibSSL.ssl_ctrl(
            ssl,
            LibSSL::SSLCtrl::SET_TLSEXT_HOSTNAME,
            LibSSL::TLSExt::NAMETYPE_host_name,
            host.to_unsafe.as(Pointer(Void)),
          )
          if LibSSL.ssl_connect(ssl) != 1
            # The chain check ITSELF rejected the certificate. The store's
            # verdict survives the failed handshake, and libcrypto's text for
            # that code is word-for-word what Python prints.
            code = LibSSL.ssl_get_verify_result(ssl)
            return nil if code == X509_V_OK
            text = LibCrypto.x509_verify_cert_error_string(code)
            return text ? String.new(text) : nil
          end
          # A verified chain leaves only the name able to be wrong, and
          # Python words an IP-literal mismatch differently ("IP address
          # mismatch, ..."), so those keep Crystal's own text.
          return nil if ::Socket::IPAddress.valid?(host)

          cert = LibSSL.ssl_get_peer_certificate(ssl)
          return nil unless cert

          result = OpenSSL::SSL::HostnameValidation.validate_hostname(host, cert)
          begin
            return nil if result == OpenSSL::SSL::HostnameValidation::Result::MatchFound
            "Hostname mismatch, certificate is not valid for '#{host}'."
          ensure
            LibCrypto.x509_free(cert)
          end
        ensure
          # SSL_set_bio transfers the BIO to the SSL object, so SSL_free is
          # what disposes of it (as in Socket#finalize); the TCP socket is
          # this code's own sync_close equivalent.
          LibSSL.ssl_free(ssl)
          tcp.close rescue nil
        end
      rescue
        nil
      end

      # The 401-challenge retry and the redirect hop, both of which re-run
      # the whole download and hand their result back to the caller:
      # returns the new hop's Result, or nil when neither applies.
      private def self.redirect_hop(
        client : HTTP::Client,
        uri : URI,
        response : HTTP::Client::Response,
        url : String,
        dest : String,
        options : Options,
        redirects_left : Int32,
        auth_attempted : Bool,
        cookie_jar : CookieJar,
      ) : Result?
        challenge_relevant = !auth_attempted && !options.force_basic_auth
        if challenge_relevant && response.status_code == 401 &&
           options.username && options.password
          client.close
          return download_with_info(url, dest, options, redirects_left, auth_attempted: true, cookie_jar: cookie_jar)
        end

        # urllib's HTTPRedirectHandler follows exactly 301/302/303/307 for
        # GET; any other 3xx falls through to the default error handler and
        # raises HTTPError("<code>: <reason>"). 308 is the case that bites:
        # urllib only learned it in Python 3.11, and the Pythons (<= 3.10)
        # that run ansible's modules on the benchmark hosts fail the task
        # with "Request failed", status_code 308 (issues #737 and #656, same
        # root cause as apt_key's #427, whose download_key_url mirrors this
        # same set). A non-empty Location does NOT bring a code into the
        # followed set - only the 30x dispatch table decides that.
        if {301, 302, 303, 307}.includes?(response.status_code) &&
           (location = response.headers["Location"]?) && !location.empty?
          client.close
          return download_with_info(resolve_redirect(uri, location), dest, redirect_options(options), redirects_left - 1, cookie_jar: cookie_jar)
        end

        nil
      end

      # Python words a TLS read timeout differently from a plaintext one:
      # ssl reads surface ssl.SSLError("The read operation timed out"),
      # while a plain socket read is the bare socket.timeout's "timed
      # out". Every read on the connection times out that way - the wait
      # for the response head as much as the body copy - so both
      # fetch_url's OSError text and get_url's copyfileobj text depend on
      # the URL scheme, not on anything in the response.
      def self.read_timeout_reason(scheme : String) : String
        scheme.downcase == "https" ? "The read operation timed out" : "timed out"
      end

      # Streams the response body onto the staging path. perm 0666 (not
      # Crystal's 0644 default): this staged file becomes the final dest
      # after the rename, and Ansible's atomic_move gives a new dest
      # 0666 & ~umask (umask 002 -> 0664, umask 022 -> 0644). Ignored when
      # overwriting an existing file.
      #
      # A failure HERE is not fetch_url's - the request was fine and
      # returned - so it is get_url's own copyfileobj failure, reported
      # with str(ex) as the reason.
      private def self.write_body(response : HTTP::Client::Response, dest : String, scheme : String) : Nil
        File.open(dest, "w", 0o666) do |file|
          # A HEAD response has no body (python's http.client reads zero
          # bytes for HEAD whatever Content-Length claims), so the staged
          # file stays empty - the exact copy get_url.py's check-mode
          # comparison sees.
          IO.copy(response.body_io, file) if response.body_io?
        end
      rescue IO::TimeoutError
        raise FetchError.new(FetchError::Kind::ContentCopy, "", reason: read_timeout_reason(scheme))
      rescue ex
        raise FetchError.new(FetchError::Kind::ContentCopy, "", reason: copy_failure_reason(ex))
      end

      # to_native() of whatever get_url's copyfileobj handler caught. An OS
      # error on the write (a full staging filesystem: "[Errno 28] No space
      # left on device") is Python's bare str(OSError) - errno and strerror
      # with NO path, because the call that failed is the file object's own
      # write, which raises with filename=None. Crystal's IO::Error message
      # names the staging file ("write (<path>): <strerror>"), which ansible
      # never prints, so rebuild the Python shape from the errno it carries.
      def self.copy_failure_reason(ex : Exception) : String
        if errno = ex.as?(IO::Error).try(&.os_error).as?(Errno)
          return SocketConnect.python_error_text(errno) unless errno.none?
        end
        ex.message || ex.class.name
      end

      # urllib.error.HTTPError's str(): the code and the server's own
      # reason phrase. HTTP::Client::Response#status_message is the text
      # that came off the status line (falling back to Crystal's own
      # HTTP::Status description when a server sends none), which is the
      # same thing: a python http.server answers 404 with "File not
      # found", not "Not Found".
      private def self.http_error(response : HTTP::Client::Response) : FetchError
        code = response.status_code
        reason = response.status_message || response.status.description
        FetchError.new(FetchError::Kind::HttpError, "HTTP Error #{code}: #{reason}", status_code: code)
      end

      # A connect timeout is raised before urllib hands the request
      # to the socket layer and comes back wrapped in a URLError
      # ("Request failed: <urlopen error timed out>"); a timeout
      # waiting for the response head is a bare timeout on the socket
      # layer, which fetch_url's OSError branch prefixes with
      # "Connection failure: " and whose own text is python's
      # scheme-dependent read-timeout wording (see
      # read_timeout_reason). Crystal reports the two with different
      # messages.
      private def self.timeout_failure(ex : IO::TimeoutError, scheme : String) : FetchError
        if connect_timeout?(ex)
          FetchError.new(FetchError::Kind::UrlError, "Request failed: <urlopen error timed out>")
        else
          FetchError.new(FetchError::Kind::ConnectionFailure, "Connection failure: #{read_timeout_reason(scheme)}")
        end
      end

      private def self.connect_timeout?(ex : IO::TimeoutError) : Bool
        ex.message.to_s.downcase.includes?("connect")
      end

      # A redirect hop drops the headers named in unredirected_headers
      # (Ansible's fetch_url applies the same list after each
      # redirect). The remaining headers, and the auth credentials they
      # were derived from, carry over untouched.
      private def self.redirect_options(options : Options) : Options
        # A redirected request's verb: urllib only carries a HEAD over to
        # the next hop on Python 3.13+ (see Options#redirected_head_becomes_get),
        # where every earlier stdlib rebuilds the Request as a GET.
        hop_method = options.redirected_head_becomes_get && options.method == "HEAD" ? "GET" : options.method

        headers = options.headers
        unless options.unredirected_headers.empty?
          headers = options.headers.dup
          options.unredirected_headers.each { |name| headers.delete(name) }
        end

        Options.new(
          max_redirects: options.max_redirects,
          connect_timeout: options.connect_timeout,
          read_timeout: options.read_timeout,
          headers: headers,
          verify_tls: options.verify_tls,
          username: options.username,
          password: options.password,
          force_basic_auth: options.force_basic_auth,
          client_cert: options.client_cert,
          client_key: options.client_key,
          ciphers: options.ciphers,
          unredirected_headers: options.unredirected_headers,
          # urllib re-applies the proxy per redirected request too
          http_proxy: options.http_proxy,
          https_proxy: options.https_proxy,
          no_proxy: options.no_proxy,
          method: hop_method,
          redirected_head_becomes_get: options.redirected_head_becomes_get,
        )
      end

      # force_basic_auth sends Authorization up front; the 401-challenge
      # retry (auth_attempted) re-requests with it after the server
      # asked. A redirect hop resets the challenge state - the next hop
      # goes out without credentials and re-challenges if it needs them,
      # matching urllib's per-request auth handler rather than leaking
      # auto-added credentials to an arbitrary redirect target.
      private def self.request_headers(options : Options, auth_attempted : Bool) : HTTP::Headers
        headers = options.headers
        return headers unless options.force_basic_auth || auth_attempted

        u = options.username
        p = options.password
        return headers unless u && p

        headers = headers.dup
        headers["Authorization"] = "Basic #{Base64.strict_encode("#{u}:#{p}")}"
        headers
      end

      def self.build_client(uri : URI, options : Options) : HTTP::Client
        client = HTTP::Client.new(uri)
        client.connect_timeout = options.connect_timeout
        client.read_timeout = options.read_timeout

        if !options.verify_tls && (tls = client.tls?)
          tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end

        # TLS context customization: client_cert/client_key (client-side
        # certificate auth - the key may be bundled in the cert file, in
        # which case client_key is simply absent and OpenSSL reads both
        # from the one file) and ciphers (real get_url/uri pass the
        # OpenSSL cipher-list string the same way). No-op on plain HTTP.
        if tls = client.tls?
          if cert = options.client_cert
            tls.certificate_chain = cert
          end
          if key = options.client_key
            tls.private_key = key
          end
          if ciphers = options.ciphers
            tls.ciphers = ciphers
          end
        end

        client
      end

      def self.resolve_redirect(base : URI, location : String) : String
        URI.parse(location).absolute? ? location : base.resolve(location).to_s
      end
    end
  end
end

# Crystal's own OpenSSL bindings stop short of the two calls that turn a
# failed handshake into the reason Python's ssl module reports: the store's
# X509_V_ERR_* verdict for the rejected chain, and libcrypto's text for it.
lib LibSSL
  fun ssl_get_verify_result = SSL_get_verify_result(handle : SSL) : LibC::Long
end

lib LibCrypto
  fun x509_verify_cert_error_string = X509_verify_cert_error_string(code : LibC::Long) : UInt8*
end

require "http/client"
require "uri"
require "base64"
require "./socket_connect"

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
        # Basic auth timing, mirroring real Ansible's fetch_url: true sends
        # the Authorization header on the FIRST request; false (real
        # get_url/uri's default) holds it back until a 401 challenge, then
        # retries once WITH the header. The default here is true only to
        # preserve the pre-existing behavior of the helper's original
        # consumers; get_url passes the real param's default (false) through.
        force_basic_auth : Bool = true,
        client_cert : String? = nil,
        client_key : String? = nil,
        ciphers : String? = nil,
        unredirected_headers : Array(String) = [] of String

      # What the FINAL response of a redirect-following download looked
      # like: real Ansible's get_url derives a directory-dest download's
      # filename from the final response's Content-Disposition header
      # (falling back to the FINAL post-redirect URL's basename), so
      # callers need both pieces of the last hop, not the original URL.
      record Result, final_url : String, headers : HTTP::Headers

      # A download that failed, carrying the pieces of real Ansible's
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
      # 304, which real's own url_get handles one branch higher up),
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
      ) : Result
        raise "too many redirects" if redirects_left < 0

        uri = URI.parse(url)
        client = build_client(uri, options)
        headers = request_headers(options, auth_attempted)

        begin
          client.get(uri.request_target, headers: headers) do |response|
            if hop = redirect_hop(client, uri, response, url, dest, options, redirects_left, auth_attempted)
              return hop
            end

            # Real url_get accepts ONLY 200: anything else (304 included -
            # real handles that one a branch higher up, in url_get itself)
            # is urllib's HTTPError, whose str() is "HTTP Error <code>:
            # <reason>" with the reason phrase the SERVER sent.
            raise http_error(response) unless response.status_code == 200

            write_body(response, dest)
            Result.new(final_url: url, headers: response.headers)
          end
        rescue ex : FetchError
          raise ex
        rescue ex : IO::TimeoutError
          # A connect timeout is raised before urllib hands the request
          # to the socket layer and comes back wrapped in a URLError
          # ("Request failed: <urlopen error timed out>"); a timeout
          # waiting for the response head is a bare socket.timeout
          # ("Connection failure: timed out"). Crystal reports the two
          # with different messages.
          raise connect_timeout?(ex) ? FetchError.new(FetchError::Kind::UrlError, "Request failed: <urlopen error timed out>") : FetchError.new(FetchError::Kind::ConnectionFailure, "Connection failure: timed out")
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
        end
      ensure
        client.try(&.close)
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
      ) : Result?
        challenge_relevant = !auth_attempted && !options.force_basic_auth
        if challenge_relevant && response.status_code == 401 &&
           options.username && options.password
          client.close
          return download_with_info(url, dest, options, redirects_left, auth_attempted: true)
        end

        if response.status.redirection? && (location = response.headers["Location"]?)
          client.close
          return download_with_info(resolve_redirect(uri, location), dest, redirect_options(options), redirects_left - 1)
        end

        nil
      end

      # Streams the response body onto the staging path. perm 0666 (not
      # Crystal's 0644 default): this staged file becomes the final dest
      # after the rename, and real Ansible's atomic_move gives a new dest
      # 0666 & ~umask (umask 002 -> 0664, umask 022 -> 0644). Ignored when
      # overwriting an existing file.
      #
      # A failure HERE is not fetch_url's - the request was fine and
      # returned - so it is get_url's own copyfileobj failure, reported
      # with str(ex) as the reason.
      private def self.write_body(response : HTTP::Client::Response, dest : String) : Nil
        File.open(dest, "w", 0o666) do |file|
          IO.copy(response.body_io, file)
        end
      rescue IO::TimeoutError
        raise FetchError.new(FetchError::Kind::ContentCopy, "", reason: "timed out")
      rescue ex
        raise FetchError.new(FetchError::Kind::ContentCopy, "", reason: ex.message || ex.class.name)
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

      private def self.connect_timeout?(ex : IO::TimeoutError) : Bool
        ex.message.to_s.downcase.includes?("connect")
      end

      # A redirect hop drops the headers named in unredirected_headers
      # (real Ansible's fetch_url applies the same list after each
      # redirect). The remaining headers, and the auth credentials they
      # were derived from, carry over untouched.
      private def self.redirect_options(options : Options) : Options
        return options if options.unredirected_headers.empty?

        stripped = options.headers.dup
        options.unredirected_headers.each { |name| stripped.delete(name) }
        Options.new(
          max_redirects: options.max_redirects,
          connect_timeout: options.connect_timeout,
          read_timeout: options.read_timeout,
          headers: stripped,
          verify_tls: options.verify_tls,
          username: options.username,
          password: options.password,
          force_basic_auth: options.force_basic_auth,
          client_cert: options.client_cert,
          client_key: options.client_key,
          ciphers: options.ciphers,
          unredirected_headers: options.unredirected_headers,
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

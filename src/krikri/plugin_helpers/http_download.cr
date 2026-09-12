require "http/client"
require "uri"
require "base64"

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

      # Downloads `url` to `dest`, following up to `max_redirects`
      # redirects and streaming the raw body byte-for-byte. Returns nil on
      # success; raises on non-2xx response, too many redirects, or an
      # unsupported scheme.
      #
      # `auth_attempted` tracks the 401-challenge retry: with
      # force_basic_auth: false (the real-Ansible default) the first
      # request goes out WITHOUT Authorization and exactly one retry is
      # made WITH it when the server answers 401 - a second 401 then
      # surfaces as the failure it is instead of looping.
      def self.download(
        url : String,
        dest : String,
        options : Options = Options.new,
        redirects_left : Int32 = options.max_redirects,
        auth_attempted : Bool = false,
      ) : Nil
        raise "too many redirects" if redirects_left < 0

        uri = URI.parse(url)
        client = build_client(uri, options)
        headers = request_headers(options, auth_attempted)

        client.get(uri.request_target, headers: headers) do |response|
          challenge_relevant = !auth_attempted && !options.force_basic_auth
          if challenge_relevant && response.status_code == 401 &&
             options.username && options.password
            client.close
            return download(url, dest, options, redirects_left, auth_attempted: true)
          end

          if response.status.redirection? && (location = response.headers["Location"]?)
            client.close
            return download(resolve_redirect(uri, location), dest, redirect_options(options), redirects_left - 1)
          end

          unless response.status.success?
            raise "server returned #{response.status_code} #{response.status.description}"
          end

          File.open(dest, "w") do |file|
            IO.copy(response.body_io, file)
          end
        end
      ensure
        client.try(&.close)
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

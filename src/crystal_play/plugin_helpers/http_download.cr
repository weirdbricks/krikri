require "http/client"
require "uri"

module CrystalPlay
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
        password : String? = nil

      # Downloads `url` to `dest`, following up to `max_redirects`
      # redirects and streaming the raw body byte-for-byte. Returns nil on
      # success; raises on non-2xx response, too many redirects, or an
      # unsupported scheme.
      def self.download(
        url : String,
        dest : String,
        options : Options = Options.new,
        redirects_left : Int32 = options.max_redirects,
      ) : Nil
        raise "too many redirects" if redirects_left < 0

        uri = URI.parse(url)
        client = build_client(uri, options)

        client.get(uri.request_target, headers: options.headers) do |response|
          if response.status.redirection? && (location = response.headers["Location"]?)
            client.close
            return download(resolve_redirect(uri, location), dest, options, redirects_left - 1)
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

      def self.build_client(uri : URI, options : Options) : HTTP::Client
        client = HTTP::Client.new(uri)
        client.connect_timeout = options.connect_timeout
        client.read_timeout = options.read_timeout

        if !options.verify_tls && (tls = client.tls?)
          tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end

        if (u = options.username) && (p = options.password)
          client.basic_auth(u, p)
        end

        client
      end

      def self.resolve_redirect(base : URI, location : String) : String
        URI.parse(location).absolute? ? location : base.resolve(location).to_s
      end
    end
  end
end

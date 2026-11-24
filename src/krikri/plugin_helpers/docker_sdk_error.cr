require "krikri-docker"
require "http/client"
require "json"

module Krikri
  module PluginHelpers
    # DockerSdkError - the Docker Python SDK's APIError rendering that
    # real community.docker modules quote in their failure messages:
    #
    #     500 Server Error for http+docker://localhost/v1.41/auth:
    #     Internal Server Error ("daemon's own message")
    #
    # The krikri-docker client raises its DockerAPIError with the request
    # URL, status code, reason phrase and raw body already attached, so the
    # plugins only re-word the failure here instead of re-reading anything
    # or asking the daemon again.
    module DockerSdkError
      # Raised for a pull the daemon rejected, so the failure message can
      # keep Ansible's own wording ("Error pulling image <ref> - ...")
      # instead of the generic API-error one.
      class ImagePullError < Exception
      end

      # Renders a failed krikri-docker request as the SDK's APIError text.
      #
      # The SDK always quotes a VERSIONED URL (http+docker://localhost/v1.41/
      # ...), while the client calls every endpoint unversioned, so the
      # version comes from the client's own cached negotiation and the
      # prefix is added only here, while a failure is being rendered.
      # api_version can be passed in by tests (which have no daemon to
      # negotiate with); nil means ask the client. Without a recorded URL
      # (an error raised before any request went out) there is nothing to
      # re-render, and the exception's own text is the best available
      # fallback.
      def self.api_error_text(client : KrikriDocker::Client?, params : Hash(String, String), ex : KrikriDocker::Errors::DockerAPIError, api_version : String? = nil) : String
        return ex.message || "" if client.nil? || ex.url.empty?

        version = api_version || client.api_version
        base = "#{sdk_base_url(params, client)}/v#{version}"
        kind = 400 <= ex.status_code < 500 ? "Client" : "Server"
        "#{ex.status_code} #{kind} Error for #{base}#{ex.url}: #{ex.reason} (\"#{ex.daemon_message}\")"
      end

      # The pure renderer, for a status/URL/body triple that did not come
      # from a krikri-docker response (unit tests, raw probes).
      # The status line's reason phrase, then the daemon's own message -
      # the `message` field of its JSON error body, or the raw body when
      # it isn't JSON - in quotes, omitted entirely when the body carries
      # none.
      def self.api_error_text(status : Int32, url : String, body : String) : String
        kind = 400 <= status < 500 ? "Client" : "Server"
        text = "#{status} #{kind} Error for #{url}: #{status_reason(status)}"
        explanation = daemon_message(body)
        explanation ? "#{text} (\"#{explanation}\")" : text
      end

      # The status line's reason phrase for a code, used only where the
      # daemon's own phrase is not available (the pure renderer above).
      # Crystal's HTTP::Status enum name is the closest stand-in, and for
      # the codes a Docker daemon actually answers with ("Internal Server
      # Error" on a 500) it is the very same text Ansible's message quotes.
      def self.status_reason(status : Int32) : String
        text = HTTP::Status.new(status).to_s
        # An unknown code renders as its bare number - no reason phrase to
        # quote, same as the SDK seeing an unrecognized status line.
        return "" if text.matches?(/\A\d+\z/)

        text.split('_').map(&.capitalize).join(' ')
      rescue ArgumentError
        ""
      end

      def self.daemon_message(body : String) : String?
        return nil if body.strip.empty?

        parsed = JSON.parse(body).as_h?
        message = parsed.try { |fields| fields["message"]?.try { |value| value.as_s? } }
        message || body.strip
      rescue JSON::ParseException
        body.strip
      end

      # Ansible's SDK base_url, the literal host part of every URL it quotes
      # in an error message: the http+docker:// placeholder it mounts its
      # UNIX-socket adapter under, or scheme://host:port for a TCP(+TLS)
      # daemon.
      def self.sdk_base_url(params : Hash(String, String), client : KrikriDocker::Client) : String
        # Same docker_host resolution DockerClient.build uses, kept
        # self-contained here (this helper is also required standalone by
        # its unit test): param, then the task environment: overlay's
        # DOCKER_HOST, then the plugin process's own DOCKER_HOST.
        docker_host = params["docker_host"]? || env_fallback(params, "DOCKER_HOST") || ENV["DOCKER_HOST"]?
        return "http+docker://localhost" unless tcp_docker_host?(docker_host)

        "#{client.tls? ? "https" : "http"}://#{client.host}:#{client.port}"
      end

      private def self.env_fallback(params : Hash(String, String), key : String) : String?
        raw = params["_environment"]?
        return nil unless raw
        Hash(String, String).from_json(raw)[key]?
      rescue
        nil
      end

      # Real (both docker_container and docker_image pull through
      # AnsibleDockerClientBase.pull_image) POSTs the pull itself and wraps
      # any failure in its own prefix, so the wrapped text is the SDK's
      # APIError rendering of the SDK's own versioned pull URL - which is
      # exactly what the shard's Images#pull constructs (query in the SDK's
      # "tag=" then "fromImage=" order, form-encoded).
      def self.pull_image!(client : KrikriDocker::Client, params : Hash(String, String), repository : String, tag : String, display_ref : String) : Nil
        KrikriDocker::API.new(client).images.pull(repository, tag)
      rescue ex : KrikriDocker::Errors::DockerAPIError
        raise ImagePullError.new("Error pulling image #{display_ref} - #{api_error_text(client, params, ex)}")
      end

      # Real docker_login validates registry credentials with the daemon's
      # POST /auth (docker_login.py's _login) and quotes the SDK's APIError
      # text in its "Logging into ... failed - ..." failure. Returns nil
      # when the daemon accepted the credentials, otherwise that SDK text.
      def self.registry_auth_error(client : KrikriDocker::Client, params : Hash(String, String), registry_url : String, username : String, password : String) : String?
        KrikriDocker::API.new(client).sys.auth(username, password, registry_url)
        nil
      rescue ex : KrikriDocker::Errors::DockerAPIError
        api_error_text(client, params, ex)
      end

      # Real's AnsibleDockerClientBase (module_utils/common_api.py) wraps
      # every exception escaping the SDK Client's __init__ in
      # "Error connecting: %s" - and that __init__'s api_version property
      # is the daemon's first round trip (GET /version), which is why the
      # text always carries the SDK's own "Error while fetching server
      # API version: ..." middle. The transport error after it is
      # requests' own rendering: a one-element tuple of the wrapped
      # exception's repr for a UNIX-socket connect
      # ("('Connection aborted.', FileNotFoundError(2, 'No such file or
      # directory'))"), or urllib3's pool-retry prose for a TCP one.
      # docker_host is the resolved docker_host (param or environment) and
      # tls its effective TLS state - together they pick the TCP branch's
      # pool spelling.
      def self.connect_error_text(ex : Exception, docker_host : String?, tls : Bool = false) : String
        "Error connecting: Error while fetching server API version: #{transport_error_text(ex, docker_host, tls)}"
      end

      # AnsibleDockerClientBase's wrapper for an exception escaping the
      # SDK Client's __init__ BEFORE its api_version round trip - notably
      # parse_host()'s own DockerException for an unusable docker_host:.
      # The message is the SDK's text alone, with no version-fetch middle.
      def self.client_init_error_text(ex : Exception) : String
        "Error connecting: #{ex.message}"
      end

      def self.transport_error_text(ex : Exception, docker_host : String?, tls : Bool = false) : String
        return unix_transport_error_text(ex) unless tcp_docker_host?(docker_host)

        # A scheme-less value is a TCP endpoint (the vendored parse_host's
        # urlparse("//addr") retry), so it needs that "//" here too or
        # urlparse would read the whole value as a path.
        addr = docker_host || ""
        uri = URI.parse(addr.includes?("://") ? addr : "//#{addr}")
        # The same reset parse_host applies to an explicit http/https
        # scheme: https forces TLS, http forces it off, and only a value
        # naming neither transport takes the caller's state.
        https = if addr.starts_with?("https://")
                  true
                elsif addr.starts_with?("http://")
                  false
                else
                  tls
                end
        tcp_transport_error_text(ex, uri, https)
      end

      # TCP unless the value names another transport. A scheme-less value
      # is TCP: real's parse_host falls back to it, so "docker_host:
      # spcyng" fails with urllib3's pool prose for spcyng:2376, not the
      # UNIX-socket tuple.
      private def self.tcp_docker_host?(docker_host : String?) : Bool
        return false unless host = docker_host.try(&.strip)
        return false if host.empty?
        return true if {"tcp://", "http://", "https://"}.any? { |scheme| host.starts_with?(scheme) }

        !{"unix://", "npipe://", "ssh://", "fd://"}.any? { |scheme| host.starts_with?(scheme) } && !host.starts_with?('/')
      end

      private def self.tcp_transport_error_text(ex : Exception, uri : URI, https : Bool) : String
        host = uri.host || ""
        # The vendored parse_host's own pair: TLS takes 2375, plain 2376
        # (verified live against community.docker 5.2.1 - "tcp://h" and a
        # scheme-less host both report port=2376, tls:/https report 2375).
        port = uri.port || (https ? 2375 : 2376)
        pool = "#{https ? "HTTPS" : "HTTP"}ConnectionPool(host='#{host}', port=#{port})"
        # urllib3 renders the failed connection attempt's own object
        # address in the cause ("...HTTPConnection object at 0x7fa5..."),
        # which is the Python process's live heap pointer - real's own
        # text is not stable across runs there, so this quotes THIS
        # process's exception object id in the same shape.
        connection = "urllib3.connection.#{https ? "HTTPS" : "HTTP"}Connection object at 0x#{ex.object_id.to_s(16).rjust(12, '0')}"
        "#{pool}: Max retries exceeded with url: /version (Caused by #{connection_error_cause(ex, host, port, connection)})"
      end

      # A failed name lookup is urllib3's NameResolutionError, not a
      # NewConnectionError: requests never gets as far as a socket.
      private def self.connection_error_cause(ex : Exception, host : String, port : Int32, connection : String) : String
        if dns_error = ex.as?(Socket::Addrinfo::Error)
          "NameResolutionError(\"<#{connection}>: Failed to resolve '#{host}' (#{gai_error_text(dns_error)})\")"
        elsif connect_error = ex.as?(Socket::ConnectError)
          "NewConnectionError('<#{connection}>: Failed to establish a new connection: #{errno_cause_text(connect_error, host, port)}')"
        else
          "#{ex.message || ex.class.name}'"
        end
      end

      private def self.unix_transport_error_text(ex : Exception) : String
        if connect_error = ex.as?(Socket::ConnectError)
          "('Connection aborted.', #{wrapped_exception_text(connect_error)})"
        else
          "('Connection aborted.', #{ex.message || ex.class.name})"
        end
      end

      # socket.gaierror's own rendering of a failed name lookup
      # ("[Errno -2] Name or service not known"), which is what urllib3's
      # NameResolutionError quotes. Crystal keeps the getaddrinfo code in
      # the exception but renders its own wording, so the code is turned
      # back into glibc's text here.
      private def self.gai_error_text(ex : Socket::Addrinfo::Error) : String
        errno = ex.os_error.as?(Errno)
        return "[Errno -2] Name or service not known" unless errno

        "[Errno #{errno.value}] #{String.new(LibC.gai_strerror(errno.value))}"
      end

      private def self.errno_cause_text(ex : Socket::ConnectError, host : String? = nil, port : Int32? = nil) : String
        errno = ex.os_error.as?(Errno)
        # Crystal's non-blocking connect raises on connect()'s immediate
        # EINPROGRESS/EAGAIN return without ever reading SO_ERROR, so the
        # caught errno is never the completion verdict real's blocking
        # socket reports ("[Errno 111] Connection refused" for a closed
        # port). A blocking re-probe of the same endpoint recovers the
        # OS's actual verdict with real's own socket semantics.
        if host && port && (errno == Errno::EINPROGRESS || errno == Errno::EAGAIN)
          errno = probe_connect_errno(host, port) || errno
        end
        errno ? "[Errno #{errno.value}] #{errno.message}" : (ex.message || "connection error")
      end

      # One low-level BLOCKING connect attempt - the same socket semantics
      # real's urllib3 connect uses, so the errno it surfaces is exactly
      # the one Python would report: ECONNREFUSED (closed port) and
      # ENETUNREACH/EHOSTUNREACH fail instantly; dropped/filtered traffic
      # hangs until the kernel's own TCP timeout, exactly like real's
      # connect does before its "Connection timed out". Any probe-side
      # failure (DNS, resource) keeps the caught exception's own errno.
      private def self.probe_connect_errno(host : String, port : Int32) : Errno?
        family = host.includes?(':') ? Socket::Family::INET6 : Socket::Family::INET
        ai = Socket::Addrinfo.resolve(host, port, family: family, type: Socket::Type::STREAM).first
        fd = LibC.socket(ai.family.value, LibC::SOCK_STREAM, 0)
        return nil if fd < 0
        begin
          rc = LibC.connect(fd, ai.to_unsafe, LibC::SocklenT.new(ai.size))
          rc == 0 ? nil : Errno.new(Errno.value)
        ensure
          LibC.close(fd)
        end
      rescue
        nil
      end

      # Python's repr of the exception requests wraps for a UNIX-socket
      # connect failure, byte-verified against community.docker 5.2.1
      # driving podman's docker-compatible socket: the tuples real's
      # "Error connecting: ..." messages quote are exactly
      #     FileNotFoundError(2, 'No such file or directory')
      #     ConnectionRefusedError(111, 'Connection refused')
      #     PermissionError(13, 'Permission denied')
      # (each itself wrapped in ('Connection aborted.', ...) by requests).
      private def self.wrapped_exception_text(ex : Socket::ConnectError) : String
        errno = ex.os_error.as?(Errno)
        return "OSError('#{ex.message}')" unless errno

        case errno
        when .enoent?       then "FileNotFoundError(2, 'No such file or directory')"
        when .econnrefused? then "ConnectionRefusedError(111, 'Connection refused')"
        when .eacces?       then "PermissionError(13, 'Permission denied')"
        when .econnreset?   then "ConnectionResetError(104, 'Connection reset by peer')"
        else                     "OSError(#{errno.value}, '#{errno.message}')"
        end
      end
    end
  end
end

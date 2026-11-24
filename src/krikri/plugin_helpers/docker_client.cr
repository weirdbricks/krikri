require "krikri-docker"
require "openssl"
require "./docker_sdk_error"
require "./python_lib_gate"

module Krikri
  module PluginHelpers
    # DockerClient - builds a KrikriDocker::Client from a docker_*.cr plugin's
    # own params, supporting both the common case (a local/rootless
    # UNIX socket) and a remote TCP(+TLS) daemon. Shared by
    # docker_container.cr/docker_image.cr/docker_network.cr instead of
    # each duplicating the same docker_host:/TLS param parsing.
    #
    # - docker_host: "unix:///path/to.sock" / "tcp://host:port" /
    #   "https://host:port" - defaults to the DOCKER_HOST environment
    #   variable (the same convention the Docker CLI and every other
    #   Docker SDK honor), falling back further to KrikriDocker::Client's own
    #   UNIX-socket default when neither is set. Parsed the way the SDK's
    #   parse_host() reads it (see #parse_host), so a value real rejects
    #   fails here too instead of being read as a socket path.
    # - tls: bool, default false (or the DOCKER_TLS env var if the param
    #   itself is omitted, matching Ansible's own documented
    #   fallback) - secures the connection with TLS *without* verifying
    #   the server's certificate. validate_certs: true takes precedence
    #   over this if both are given, matching Ansible's own
    #   documented behavior exactly (verified against its source, not
    #   assumed from a one-line doc summary) - cert paths alone, with
    #   neither tls: nor validate_certs: set (as a param or via their
    #   own env vars), do NOT turn on TLS on their own (a real,
    #   easy-to-get-wrong distinction: this codebase originally inferred
    #   TLS from cert-path presence alone, which Ansible's own
    #   community.docker collection does not - confirmed the hard way,
    #   by getting a real "Client sent an HTTP request to an HTTPS
    #   server" error from Ansible until this was fixed to require
    #   an explicit tls:/validate_certs: flag).
    # - validate_certs (alias tls_verify): bool, default false (or the
    #   DOCKER_TLS_VERIFY env var) - secures the connection with TLS
    #   *and* verifies the server's certificate against cacert_path:.
    # - cacert_path: / cert_path: / key_path: - CA/client cert/client
    #   key file paths. If none of the three are given as params and
    #   DOCKER_CERT_PATH is set, falls back to
    #   $DOCKER_CERT_PATH/ca.pem/cert.pem/key.pem respectively - the
    #   Docker CLI's own convention (Ansible does the same:
    #   verified against its source, not assumed) - explicit params
    #   always win over the env var fallback, but it's all-or-nothing
    #   with DOCKER_CERT_PATH itself (no mixing one explicit path with
    #   two env-derived ones).
    # - tls_hostname: - overrides which hostname the TLS handshake
    #   verifies the server's certificate against, independent of
    #   docker_host:'s own host (which is still what's actually
    #   connected to) - the common docker-machine-style setup of
    #   reaching a daemon via a raw IP while its certificate is issued
    #   for a fixed name like "localhost". Implemented in the
    #   krikri-docker shard itself: `KrikriDocker::Client`'s TCP(+TLS)
    #   constructor takes an optional `tls_hostname` param, and `#io`
    #   reimplements `HTTP::Client`'s own TCP+TLS connection logic (rather
    #   than deferring to it via `super`, which it still does for the
    #   ordinary same-hostname case) only when this is set - plain
    #   `HTTP::Client` has no hook to override just the verification
    #   hostname while still connecting to a different one.
    #
    # Not implemented: pinning the requests to an `api_version:` (the
    # krikri-docker client sends no version prefix on any endpoint URL, on
    # a local socket either - it caches the daemon's negotiated version
    # only for rendering SDK-style failure text). The VALUE is still
    # validated, though: real's SDK Client.__init__ parses an explicitly
    # pinned version and fails client construction on a bad one (see
    # #validate_api_version!), and skipping that made every chaos playbook
    # carrying a bogus `api_version:` diverge - krikri ran the task where
    # real failed it.
    module DockerClient
      # Real community.docker's DOCKER_COMMON_ARGS:
      # the connection parameters every API module's argument_spec merges
      # in (the module spec overrides these on key collision), with their
      # aliases. Keys the plugins' own validation must treat as legal and
      # type-convert (timeout int; tls/use_ssh_client/validate_certs/debug
      # bool) - AnsibleModule validation runs over the MERGED spec,
      # so an invalid `timeout:` fails a docker_network task exactly the
      # same as a docker_login one.
      COMMON_SPEC = {
        "api_version"    => %w[docker_api_version],
        "ca_path"        => %w[ca_cert cacert_path tls_ca_cert],
        "client_cert"    => %w[cert_path tls_client_cert],
        "client_key"     => %w[key_path tls_client_key],
        "debug"          => [] of String,
        "docker_host"    => %w[docker_url],
        "timeout"        => [] of String,
        "tls"            => [] of String,
        "tls_hostname"   => [] of String,
        "use_ssh_client" => [] of String,
        "validate_certs" => %w[tls_verify],
      }
      # _util.py's DOCKER_REQUIRED_TOGETHER - shared by every API module.
      COMMON_REQUIRED_TOGETHER = %w[client_cert client_key]

      # _api/errors.py's TLSParameterError appends this to every TLS setup
      # failure, and _common_api.py's fail_function prefixes the message
      # with "TLS config error: " on top of that.
      TLS_PARAMETER_SUFFIX = ". TLS configurations should map the Docker CLI " \
                             "client configurations. See https://docs.docker.com/engine/articles/https/ " \
                             "for API details."

      # Raised for a docker_host: the SDK's parse_host() rejects before it
      # can build a transport. Real's Client.__init__ lets the SDK's
      # DockerException escape and AnsibleDockerClientBase wraps it in
      # "Error connecting: <text>" - note the missing "Error while
      # fetching server API version:" middle, since this happens before
      # the api_version round trip.
      class InvalidDockerHostError < Exception
      end

      # docker_host: as parse_host() reads it: a UNIX socket path, or a
      # TCP endpoint (host + port).
      record ParsedHost, socket_path : String?, host : String?, port : Int32? do
        def tcp? : Bool
          !host.nil?
        end
      end

      # Raised by sdk_import_gate so BasePlugin#run_and_capture can turn it
      # into the exact failure real's client construction produces (msg in
      # the result, detail in the [ERROR] block only). The class itself
      # lives in base_plugin.cr (like OwnerLookupFailure) because every
      # plugin binary compiles base_plugin, but only the docker ones
      # compile this helper.
      # The import gate real's five API modules run at client construction.
      # community.docker 5.2.1's docker_container/docker_image/
      # docker_network/docker_network_info/docker_login import the
      # collection's VENDORED Docker SDK (module_utils/_common_api + _api/),
      # NOT the external `docker` package - live-probed with the pinned
      # pair (ansible-core 2.19.11 + 5.2.1): a python3-docker-less target
      # runs docker_network fine. The gate their client init enforces is
      # the vendored SDK's own _api/api/client.py fail_on_missing_imports
      # (reached through AnsibleDockerClientBase.__init__ AFTER TLS
      # parameter validation): `requests` must import, else the module
      # fails with missing_required_lib("requests") wording, the
      # traceback only in the [ERROR] block. (_common.py's external-SDK
      # gate - the "Docker SDK for Python: docker>=5.0.0" wording and its
      # MIN_DOCKER_VERSION version check - belongs to the _common.py
      # consumers, the docker_swarm*/docker_node*/docker_config/
      # docker_secret family this engine does not implement; there is no
      # version branch on the vendored path.) krikri talks to the Docker
      # Engine API directly (krikri-docker) and needs no `requests` either,
      # so without this gate it carried on where real stops.
      #
      # Runs at the same point real's does: after TLS parameter validation,
      # before the client is constructed, so before any network I/O.
      # Memoized per plugin process (one task = one process).
      @@gate_checked = false

      def self.sdk_import_gate : Nil
        return if @@gate_checked
        @@gate_checked = true
        return unless gate = Krikri.missing_python_library("requests", "requests")
        # The docker modules' fail_json carries no `exception`, so real's
        # [ERROR] block is the bare msg - no ": No module named 'requests'".
        raise SdkImportGateError.new(gate[:msg], gate[:msg])
      end

      # Clears the per-process memoization above - the specs run several
      # gate calls in ONE process, where a task gets a fresh process each.
      def self.reset_sdk_import_gate : Nil
        @@gate_checked = false
      end

      # _api/constants.py's MINIMUM_DOCKER_API_VERSION, which
      # Client.__init__ rejects below inside the "Error connecting:"
      # wrapper, and _common_api.py's fallback for a module that passes
      # no min_docker_api_version: (none of the five SDK-based modules
      # this engine implements does), which fails with its own bare
      # message.
      MINIMUM_DOCKER_API_VERSION     = "1.21"
      DEFAULT_MIN_DOCKER_API_VERSION = "1.25"

      # distutils.version.StrictVersion's grammar, the parser behind the
      # vendored SDK's version_lt: [major].[minor][.[patch]][a|b<N>].
      private record ApiVersion, major : Int32, minor : Int32, patch : Int32, prerelease : Bool

      private def self.parse_strict_version(value : String) : ApiVersion?
        match = value.match(/\A([0-9]+)\.([0-9]+)(?:\.([0-9]+))?([ab]([0-9]+))?\z/)
        return nil unless match

        major = match[1].to_i32?
        minor = match[2].to_i32?
        return nil unless major && minor

        patch = 0
        if raw_patch = match[3]?
          patch = raw_patch.to_i32? || return nil
        end

        ApiVersion.new(major, minor, patch, !match[4]?.nil?)
      end

      # StrictVersion ordering against a release-form minimum:
      # major.minor.patch decide first, then a prerelease ("1.25a1")
      # sorts BELOW the bare release.
      private def self.version_lt?(version : ApiVersion, major : Int32, minor : Int32) : Bool
        return version.major < major if version.major != major
        return version.minor < minor if version.minor != minor
        return false if version.patch > 0
        version.prerelease
      end

      # The module's own minimum, compared the way
      # AnsibleDockerClientBase compares it: with LooseVersion rather than
      # StrictVersion. That is why "1.25a1" passes while "1.24a1" fails -
      # LooseVersion splits into digit/word components ([1, 24, "a", 1]),
      # and a longer list with an equal prefix sorts ABOVE the shorter one.
      private def self.loose_version_lt?(value : String, major : Int64, minor : Int64) : Bool
        minimum = [major, minor]
        value.scan(/[0-9]+|[a-z]+/).each_with_index do |component, index|
          # Longer than [major, minor] with an equal prefix: greater.
          return false if index >= minimum.size
          if number = component[0].to_i64?
            return true if number < minimum[index]
            return false if number > minimum[index]
          else
            # Python 3 raises comparing a word with an int here; treat it
            # as not-less rather than inventing a crash krikri never sees.
            return false
          end
        end
        false
      end

      # Real's client construction parses an explicitly pinned
      # api_version before any network I/O: the vendored SDK's
      # Client.__init__ runs version_lt(version, MINIMUM_DOCKER_API_VERSION)
      # through StrictVersion, so an unparseable value raises
      # "invalid version number '<value>'", which AnsibleDockerClientBase
      # wraps in "Error connecting: ". krikri's client never prefixes
      # its URLs with a version (see the class comment), but the parse
      # MUST still fail like real's or a bogus api_version silently
      # succeeds here where real fails the task.
      def self.validate_api_version!(params : Hash(String, String)) : Nil
        version = resolved_api_version(params)
        # "auto" means "negotiate with the daemon", real's default: there
        # is no pinned value to parse.
        return if version.downcase == "auto"

        parsed = parse_strict_version(version)
        raise DockerClientConfigError.new("Error connecting: invalid version number '#{version}'") unless parsed

        if version_lt?(parsed, 1, 21)
          raise DockerClientConfigError.new("Error connecting: API versions below #{MINIMUM_DOCKER_API_VERSION} are no longer supported by this library.")
        end
        if loose_version_lt?(version, 1, 25)
          raise DockerClientConfigError.new("Docker API version is #{version}. Minimum version required is #{DEFAULT_MIN_DOCKER_API_VERSION}.")
        end
      end

      # _common_api.py's get_connect_params order: the param (or its
      # docker_api_version alias), then the DOCKER_API_VERSION env var
      # (task environment: overlay first, same as resolved_docker_host),
      # then "auto".
      def self.resolved_api_version(params : Hash(String, String)) : String
        params["api_version"]? || params["docker_api_version"]? ||
          env_overlay(params)["DOCKER_API_VERSION"]? || ENV["DOCKER_API_VERSION"]? || "auto"
      end

      # _common_api.py's get_connect_params() builds the vendored TLSConfig
      # before AnsibleDockerClientBase constructs its client at all. TLSConfig
      # refuses a client cert/key pair whose files do not both exist, and,
      # when verifying, a CA file that does not exist, so a task carrying
      # unusable cert paths fails here rather than on anything the client
      # constructor would have complained about - issue #1637's
      # docker_network_info task pairs a nonexistent client_cert/client_key
      # with a bogus api_version, and real reports the cert paths.
      def self.validate_tls_params!(params : Hash(String, String)) : Nil
        validate = tls_verify?(params)
        return unless validate || tls_requested?(params, resolved_docker_host(params), env_overlay(params))

        cacert_path, cert_path, key_path = cert_paths(params)
        # get_connect_params only forwards a client_cert tuple when BOTH
        # paths are set; one alone is AnsibleModule's required_together
        # failure, which has already fired before client construction.
        if cert_path && key_path && !(File.file?(cert_path) && File.file?(key_path))
          raise DockerClientConfigError.new("TLS config error: Path to a certificate and key files must be provided through the client_cert param#{TLS_PARAMETER_SUFFIX}")
        end
        # ca_cert is only handed to TLSConfig on the verify path.
        if validate && cacert_path && !File.file?(cacert_path)
          raise DockerClientConfigError.new("TLS config error: Invalid CA certificate provided for `ca_cert`.#{TLS_PARAMETER_SUFFIX}")
        end
      end

      def self.build(params : Hash(String, String)) : {KrikriDocker::Client, String}
        docker_host = resolved_docker_host(params)
        # Real's TLS parameter validation happens before the client is
        # constructed, so it also comes before the SDK import gate and the
        # docker_host parse below.
        validate_tls_params!(params)
        # The SDK's fail_on_missing_imports() runs at the top of
        # Client.__init__, BEFORE parse_host() - so a target missing
        # `requests` fails with the missing-library wording even when
        # docker_host: is unparsable.
        sdk_import_gate
        parsed = parse_host(docker_host, tls_enabled?(params))

        if (host = parsed.host) && (port = parsed.port)
          build_tcp(params, docker_host, host, port)
        else
          socket_path = parsed.socket_path
          # AnsibleDockerClientBase parses its pinned api_version right
          # after constructing the client (so after parse_host), and
          # before any request goes out.
          validate_api_version!(params)
          client = KrikriDocker::Client.new(socket_path)
          {client, socket_path || "default socket #{KrikriDocker::Client::DEFAULT_SOCKET_PATH}"}
        end
      end

      # "Error connecting: ..." for a failure while building or using the
      # client: an unparsable docker_host: carries the SDK's own text (its
      # client construction fails before the version round trip), any
      # other failure the requests-shaped version-fetch text.
      def self.connect_failure_text(ex : Exception, params : Hash(String, String)) : String
        return DockerSdkError.client_init_error_text(ex) if ex.is_a?(InvalidDockerHostError)
        if ex.is_a?(Socket::ConnectError) || ex.is_a?(Socket::Addrinfo::Error)
          return DockerSdkError.connect_error_text(ex, resolved_docker_host(params), tls_enabled?(params))
        end
        "Error connecting: #{ex.message}"
      end

      # The connection's effective TLS state, the same one real's
      # get_connect_params computes before handing docker_host to the SDK
      # (https:// implies it; otherwise tls:/validate_certs: or their env
      # fallbacks). The transport-error text needs it for the pool
      # spelling.
      def self.tls_enabled?(params : Hash(String, String)) : Bool
        tls_requested?(params, resolved_docker_host(params) || "", env_overlay(params))
      end

      # The collection's parse_host() (module_utils/_api/utils/utils.py),
      # the first thing its vendored Client.__init__ runs on the resolved
      # docker_host: urlparse() the value, rewrite http/https and
      # http+unix onto tcp/unix, and reject what docker cannot represent.
      # Every failure text here is the client's own DockerException
      # wording, which real reports as "Error connecting: <text>".
      #
      # A scheme-less value is a TCP endpoint (urlparse's "//addr" retry),
      # not a socket path: "docker_host: spcyng" is http://spcyng:2376,
      # NOT an error. The port a tcp/ssh endpoint omits gets defaulted
      # here (ssh 22, otherwise 2375 under TLS and 2376 without it - the
      # vendored copy's own inverted pair), so a portless docker_host
      # reaches the connection attempt where real does; issue #1635's
      # docker_image task only got as far as its bogus api_version
      # because real never rejected the host at all.
      def self.parse_host(docker_host : String?, tls : Bool = false) : ParsedHost
        return ParsedHost.new(nil, nil, nil) if docker_host.nil?
        addr = docker_host.strip
        # "" and "unix://" both mean the SDK's default socket.
        return ParsedHost.new(nil, nil, nil) if addr.empty? || addr == "unix://"

        proto, rest, tls = parse_scheme(addr, tls)
        authority, path = split_authority(rest)
        validate_authority!(addr, proto, rest, authority, path)

        case proto
        when "tcp", "ssh"
          tcp_endpoint(proto, authority, tls)
        else
          # unix, plus npipe - this client has no Windows transport, so that one
          # keeps the raw value as a socket path rather than inventing a
          # connection.
          ParsedHost.new(socket_path_for(authority, path), nil, nil)
        end
      end

      # urlparse()'s scheme detection followed by the SDK's own rewrites
      # (http/https onto tcp, http+unix onto unix). Returns the effective
      # TLS state too: the http/https branch RESETS it to "https implies
      # tls", overriding the caller's flag exactly like the vendored
      # parse_host does (its `tls = proto == 'https'` line), which is why
      # an explicit tls: on an http:// host still defaults to port 2376.
      private def self.parse_scheme(addr : String, tls : Bool) : {String, String, Bool}
        proto, rest = split_scheme(addr)
        # urlparse() finds no scheme when none is followed by ':', or when
        # the scheme has characters docker does not accept (the SDK keeps
        # only letters and '+'); such values are retried as "//addr" over
        # tcp.
        if proto.nil? || !proto.each_char.all? { |char| char.ascii_letter? || char == '+' }
          proto = "tcp"
          rest = "//#{addr}"
        end

        if proto == "http" || proto == "https"
          tls = proto == "https"
          proto = "tcp"
        end
        proto = "unix" if proto == "http+unix"

        unless %w[tcp unix npipe ssh].includes?(proto)
          raise InvalidDockerHostError.new("Invalid bind address protocol: #{addr}")
        end
        {proto, rest, tls}
      end

      # The shapes parse_host() refuses even though urlparse() can carry
      # them.
      private def self.validate_authority!(addr : String, proto : String, rest : String, authority : String, path : String) : Nil
        # Credentials, query strings, fragments and params.
        if rest.includes?('?') || rest.includes?('#') || path.includes?(';') ||
           (authority.includes?('@') && authority.split('@').first.includes?(':'))
          raise InvalidDockerHostError.new("Invalid bind address format: #{addr}")
        end

        # "tcp://" is exceptionally disallowed by convention.
        if proto == "tcp" && authority.empty?
          raise InvalidDockerHostError.new("Invalid bind address format: #{addr}")
        end

        if proto == "ssh" && !path.empty?
          raise InvalidDockerHostError.new("Invalid bind address format: no path allowed for this protocol: #{addr}")
        end
      end

      # The vendored parse_host defaults the port a tcp/ssh endpoint
      # leaves out - ssh's 22, and the 2375/2376 pair (TLS takes the
      # LOWER one, the reverse of the Docker CLI's convention). A daemon
      # is then never "invalid" for omitting a port, it is simply
      # unreachable at that default, which is what real reports.
      private def self.tcp_endpoint(proto : String, authority : String, tls : Bool) : ParsedHost
        hostname, port = authority_host_port(authority)
        port ||= (proto == "ssh" ? 22 : (tls ? 2375 : 2376))
        ParsedHost.new(nil, hostname.empty? ? "127.0.0.1" : hostname, port)
      end

      # The socket path of a unix:// URL: urlparse() puts a legacy
      # unix://path URL's first component in the authority, and the SDK
      # joins it back onto the path. Its UnixHTTPAdapter then prefixes the
      # missing "/" (unixconn.py), so "unix://var/run/docker.sock" - the
      # value aem_design.nexus ships as its docker_host default - reaches
      # /var/run/docker.sock like real does, not a path relative to the
      # plugin's working directory (issue #1357: same unreachable socket,
      # but krikri reported FileNotFoundError where real reported
      # PermissionError).
      private def self.socket_path_for(authority : String, path : String) : String?
        socket = (authority.empty? ? path : "#{authority}/#{path}").rstrip('/')
        return nil if socket.empty?
        socket.starts_with?('/') ? socket : "/#{socket}"
      end

      # Python's urlparse() scheme detection: a leading
      # [A-Za-z][A-Za-z0-9+.-]* followed by ':', with everything after the
      # colon as the remainder. {nil, addr} when there is no scheme.
      private def self.split_scheme(addr : String) : {String?, String}
        if match = addr.match(/\A([A-Za-z][A-Za-z0-9+.\-]*):(.*)\z/m)
          {match[1], match[2]}
        else
          {nil, addr}
        end
      end

      # The URL authority (everything after a leading "//", up to the path)
      # and the path remainder - urlparse()'s own split.
      private def self.split_authority(rest : String) : {String, String}
        return {"", rest} unless rest.starts_with?("//")
        after = rest[2..]
        stop = after.index(/[\/?#]/) || after.size
        {after[0...stop], after[stop..]}
      end

      # [userinfo@]host[:port] from a URL authority, bracketed IPv6
      # literals included. A nil port means the authority carried none (or
      # a non-positive/unparsable one, which the SDK treats the same).
      private def self.authority_host_port(authority : String) : {String, Int32?}
        host_port = authority.includes?('@') ? authority.split('@').last : authority

        if host_port.starts_with?('[')
          close = host_port.index(']')
          return {host_port, nil} unless close
          rest = host_port[(close + 1)..]
          return {host_port[1...close], positive_port(rest[1..])} if rest.starts_with?(':')
          return {host_port[1...close], nil}
        end

        host, _, port_text = host_port.rpartition(':')
        return {host_port, nil} if host.empty?
        {host, positive_port(port_text)}
      end

      private def self.positive_port(text : String) : Int32?
        port = text.to_i?
        port && port > 0 ? port : nil
      end

      # The docker_host the plugin will actually talk to: the docker_host:
      # param, then the task's own environment: overlay's DOCKER_HOST
      # (forwarded under the _environment param key), then the plugin
      # process's own DOCKER_HOST. Real's env_fallback reads the module
      # process's os.environ, and Ansible applies the task environment:
      # to that process - which the local plugin daemon deliberately does
      # not do (see LocalPluginDaemon's doc comment), so the overlay has
      # to be consulted explicitly.
      def self.resolved_docker_host(params : Hash(String, String)) : String?
        params["docker_host"]? || env_overlay(params)["DOCKER_HOST"]? || ENV["DOCKER_HOST"]?
      end

      # The task's environment: overlay as a plain hash (empty when the
      # task set none or the blob is malformed - the overlay is only ever
      # READ here for specific keys, so unlike BasePlugin#task_environment
      # no key validation is needed).
      def self.env_overlay(params : Hash(String, String)) : Hash(String, String)
        raw = params["_environment"]?
        return {} of String => String unless raw
        Hash(String, String).from_json(raw)
      rescue
        {} of String => String
      end

      private def self.build_tcp(params : Hash(String, String), docker_host : String?, host : String, port : Int32) : {KrikriDocker::Client, String}
        tls_hostname = params["tls_hostname"]? || env_overlay(params)["DOCKER_TLS_HOSTNAME"]? || ENV["DOCKER_TLS_HOSTNAME"]?

        tls = build_tls_context(params, docker_host)
        validate_api_version!(params)
        client = KrikriDocker::Client.new(host, port, tls, tls_hostname)
        {client, "#{docker_host}#{tls ? " (TLS)" : ""}"}
      end

      # nil (plain TCP, no TLS at all) unless docker_host: is https://
      # or tls:/validate_certs: was explicitly given (as a param or via
      # DOCKER_TLS/DOCKER_TLS_VERIFY) - see the class doc comment above
      # for why cert paths alone deliberately do NOT trigger this.
      private def self.build_tls_context(params : Hash(String, String), docker_host : String?) : OpenSSL::SSL::Context::Client?
        overlay = env_overlay(params)
        return nil unless tls_requested?(params, docker_host, overlay)
        validate = tls_verify?(params)

        cacert_path, cert_path, key_path = cert_paths(params)
        context = OpenSSL::SSL::Context::Client.new
        context.ca_certificates = cacert_path if cacert_path
        context.certificate_chain = cert_path if cert_path
        context.private_key = key_path if key_path
        context.verify_mode = validate ? OpenSSL::SSL::VerifyMode::PEER : OpenSSL::SSL::VerifyMode::NONE
        context
      end

      # https:// implies TLS on its own; otherwise an explicit tls:/
      # validate_certs: param or their DOCKER_TLS/DOCKER_TLS_VERIFY env
      # fallbacks (task environment: overlay first) turn it on - see the
      # class doc comment for why cert paths alone do not.
      private def self.tls_requested?(params : Hash(String, String), docker_host : String?, overlay : Hash(String, String)) : Bool
        return true if docker_host.try(&.starts_with?("https://"))
        return true if flag?(params["tls"]? || overlay["DOCKER_TLS"]? || ENV["DOCKER_TLS"]?)

        tls_verify?(params)
      end

      # validate_certs: (alias tls_verify:), or the DOCKER_TLS_VERIFY fallback
      # from the task environment / the plugin's own environment - real's
      # auth_params resolves it param first, then env, then its default.
      private def self.tls_verify?(params : Hash(String, String)) : Bool
        flag?(params["validate_certs"]? || params["tls_verify"]? ||
              env_overlay(params)["DOCKER_TLS_VERIFY"]? || ENV["DOCKER_TLS_VERIFY"]?)
      end

      # Explicit cacert_path:/cert_path:/key_path: params win outright;
      # only when *none* of the three is given does DOCKER_CERT_PATH's
      # own ca.pem/cert.pem/key.pem convention kick in, matching
      # Ansible's own documented behavior (verified against its source).
      # AnsibleModule hands the module canonical names, so a task using
      # client_cert:/client_key:/ca_path: must be read under those too -
      # real's auth_params keys them cert_path/key_path/cacert_path.
      private def self.cert_paths(params : Hash(String, String)) : {String?, String?, String?}
        cacert_path = first_param(params, "ca_path", "cacert_path", "ca_cert", "tls_ca_cert")
        cert_path = first_param(params, "client_cert", "cert_path", "tls_client_cert")
        key_path = first_param(params, "client_key", "key_path", "tls_client_key")
        return {cacert_path, cert_path, key_path} if cacert_path || cert_path || key_path

        return {nil, nil, nil} unless cert_dir = docker_cert_path(params)
        {File.join(cert_dir, "ca.pem"), File.join(cert_dir, "cert.pem"), File.join(cert_dir, "key.pem")}
      end

      # The value a task carries under a param's canonical name or one of
      # its aliases - AnsibleModule validates the merged spec but keeps
      # whichever spelling the task itself used.
      private def self.first_param(params : Hash(String, String), *names : String) : String?
        names.each do |name|
          value = params[name]?
          return value if value
        end
        nil
      end

      # DOCKER_CERT_PATH's ca.pem/cert.pem/key.pem directory, task
      # environment overlay first.
      private def self.docker_cert_path(params : Hash(String, String)) : String?
        env_overlay(params)["DOCKER_CERT_PATH"]? || ENV["DOCKER_CERT_PATH"]?
      end

      private def self.flag?(value : String?) : Bool
        !!value && ["true", "yes", "1", "on"].includes?(value.downcase)
      end
    end
  end
end

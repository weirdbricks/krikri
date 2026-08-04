require "docr"
require "openssl"

module CrystalPlay
  module PluginHelpers
    # DockerClient - builds a Docr::Client from a docker_*.cr plugin's
    # own params, supporting both the common case (a local/rootless
    # UNIX socket) and a remote TCP(+TLS) daemon. Shared by
    # docker_container.cr/docker_image.cr/docker_network.cr instead of
    # each duplicating the same docker_host:/TLS param parsing.
    #
    # - docker_host: "unix:///path/to.sock" (or a bare path) /
    #   "tcp://host:port" / "https://host:port" - defaults to the
    #   DOCKER_HOST environment variable (the same convention the Docker
    #   CLI and every other Docker SDK honor), falling back further to
    #   Docr::Client's own UNIX-socket default when neither is set.
    # - tls: bool, default false - secures the connection with TLS
    #   *without* verifying the server's certificate. validate_certs:
    #   true takes precedence over this if both are given, matching real
    #   Ansible's own documented behavior exactly (verified against its
    #   source, not assumed from a one-line doc summary) - cert paths
    #   alone, with neither tls: nor validate_certs: set, do NOT turn on
    #   TLS on their own (a real, easy-to-get-wrong distinction: this
    #   codebase originally inferred TLS from cert-path presence alone,
    #   which real Ansible's own community.docker collection does not -
    #   confirmed the hard way, by getting a real "Client sent an HTTP
    #   request to an HTTPS server" error from real Ansible until this
    #   was fixed to require an explicit tls:/validate_certs: flag).
    # - validate_certs (alias tls_verify): bool, default false - secures
    #   the connection with TLS *and* verifies the server's certificate
    #   against cacert_path:.
    # - cacert_path: / cert_path: / key_path: - CA/client cert/client
    #   key file paths, matching real Ansible's own param names exactly
    #   (not the Docker CLI's own DOCKER_CERT_PATH-relative
    #   ca.pem/cert.pem/key.pem convention - this codebase takes
    #   explicit full paths instead, a documented simplification).
    #
    # Not implemented: `tls_hostname:` (real Ansible's own "connect to
    # this host/IP but verify the certificate against a *different*
    # hostname" override, for the common docker-machine-style setup
    # where a cert is issued for "localhost" but reached via a
    # forwarded IP) - the certificate is always verified against
    # whichever host docker_host: itself names, matching plain
    # `HTTP::Client`'s own TLS behavior (used unmodified via `super` in
    # `Docr::Client#io` - see its own doc comment) rather than
    # reimplementing TCP/TLS connection setup from scratch just to
    # support a split connect-vs-verify hostname; `api_version:` (this
    # codebase doesn't version-negotiate the Docker API at all, on a
    # local socket either); `DOCKER_TLS`/`DOCKER_TLS_VERIFY`/
    # `DOCKER_CERT_PATH` environment variable fallbacks (only
    # `DOCKER_HOST` is honored as an env var here, matching every other
    # plugin in this codebase's existing DOCKER_HOST-only convention -
    # the TLS params themselves must be passed as module params).
    module DockerClient
      def self.build(params : Hash(String, String)) : {Docr::Client, String}
        docker_host = params["docker_host"]? || ENV["DOCKER_HOST"]?

        if docker_host && (docker_host.starts_with?("tcp://") || docker_host.starts_with?("https://") || docker_host.starts_with?("http://"))
          build_tcp(params, docker_host)
        else
          socket_path = docker_host.try(&.sub(/^unix:\/\//, ""))
          client = Docr::Client.new(socket_path)
          {client, socket_path || "default socket #{Docr::Client::DEFAULT_SOCKET_PATH}"}
        end
      end

      private def self.build_tcp(params : Hash(String, String), docker_host : String) : {Docr::Client, String}
        uri = URI.parse(docker_host)
        host = uri.host || raise "docker_host: '#{docker_host}' is missing a hostname"
        port = uri.port || 2376

        tls = build_tls_context(params, docker_host)
        client = Docr::Client.new(host, port, tls)
        {client, "#{docker_host}#{tls ? " (TLS)" : ""}"}
      end

      # nil (plain TCP, no TLS at all) unless docker_host: is https://
      # or tls:/validate_certs: was explicitly given - see the class doc
      # comment above for why cert paths alone deliberately do NOT
      # trigger this.
      private def self.build_tls_context(params : Hash(String, String), docker_host : String) : OpenSSL::SSL::Context::Client?
        validate = flag?(params, "validate_certs") || flag?(params, "tls_verify")
        return nil unless docker_host.starts_with?("https://") || validate || flag?(params, "tls")

        context = OpenSSL::SSL::Context::Client.new
        if cacert_path = params["cacert_path"]?
          context.ca_certificates = cacert_path
        end
        if cert_path = params["cert_path"]?
          context.certificate_chain = cert_path
        end
        if key_path = params["key_path"]?
          context.private_key = key_path
        end
        context.verify_mode = validate ? OpenSSL::SSL::VerifyMode::PEER : OpenSSL::SSL::VerifyMode::NONE
        context
      end

      private def self.flag?(params : Hash(String, String), key : String) : Bool
        value = params[key]?
        !!value && ["true", "yes", "1", "on"].includes?(value.downcase)
      end
    end
  end
end

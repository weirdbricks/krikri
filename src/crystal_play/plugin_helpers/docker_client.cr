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
    # - tls: bool, default false (or the DOCKER_TLS env var if the param
    #   itself is omitted, matching real Ansible's own documented
    #   fallback) - secures the connection with TLS *without* verifying
    #   the server's certificate. validate_certs: true takes precedence
    #   over this if both are given, matching real Ansible's own
    #   documented behavior exactly (verified against its source, not
    #   assumed from a one-line doc summary) - cert paths alone, with
    #   neither tls: nor validate_certs: set (as a param or via their
    #   own env vars), do NOT turn on TLS on their own (a real,
    #   easy-to-get-wrong distinction: this codebase originally inferred
    #   TLS from cert-path presence alone, which real Ansible's own
    #   community.docker collection does not - confirmed the hard way,
    #   by getting a real "Client sent an HTTP request to an HTTPS
    #   server" error from real Ansible until this was fixed to require
    #   an explicit tls:/validate_certs: flag).
    # - validate_certs (alias tls_verify): bool, default false (or the
    #   DOCKER_TLS_VERIFY env var) - secures the connection with TLS
    #   *and* verifies the server's certificate against cacert_path:.
    # - cacert_path: / cert_path: / key_path: - CA/client cert/client
    #   key file paths. If none of the three are given as params and
    #   DOCKER_CERT_PATH is set, falls back to
    #   $DOCKER_CERT_PATH/ca.pem/cert.pem/key.pem respectively - the
    #   Docker CLI's own convention (real Ansible does the same:
    #   verified against its source, not assumed) - explicit params
    #   always win over the env var fallback, but it's all-or-nothing
    #   with DOCKER_CERT_PATH itself (no mixing one explicit path with
    #   two env-derived ones).
    # - tls_hostname: - overrides which hostname the TLS handshake
    #   verifies the server's certificate against, independent of
    #   docker_host:'s own host (which is still what's actually
    #   connected to) - the common docker-machine-style setup of
    #   reaching a daemon via a raw IP while its certificate is issued
    #   for a fixed name like "localhost". Implemented in `docr` itself
    #   (a real shard change, not a local patch - see its own commit
    #   history): `Docr::Client`'s TCP(+TLS) constructor gained an
    #   optional `tls_hostname` param, and `#io` reimplements
    #   `HTTP::Client`'s own TCP+TLS connection logic (rather than
    #   deferring to it via `super`, which it still does for the
    #   ordinary same-hostname case) only when this is set - plain
    #   `HTTP::Client` has no hook to override just the verification
    #   hostname while still connecting to a different one.
    #
    # Not implemented: `api_version:` (this codebase's `docr`-based API
    # calls have no version prefix on any endpoint URL at all, on a
    # local socket either - adding version negotiation would mean
    # touching every endpoint across `docr`, not just connection setup
    # here, a meaningfully bigger change than anything else in this
    # file).
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
        tls_hostname = params["tls_hostname"]? || ENV["DOCKER_TLS_HOSTNAME"]?

        tls = build_tls_context(params, docker_host)
        client = Docr::Client.new(host, port, tls, tls_hostname)
        {client, "#{docker_host}#{tls ? " (TLS)" : ""}"}
      end

      # nil (plain TCP, no TLS at all) unless docker_host: is https://
      # or tls:/validate_certs: was explicitly given (as a param or via
      # DOCKER_TLS/DOCKER_TLS_VERIFY) - see the class doc comment above
      # for why cert paths alone deliberately do NOT trigger this.
      private def self.build_tls_context(params : Hash(String, String), docker_host : String) : OpenSSL::SSL::Context::Client?
        validate = flag?(params["validate_certs"]? || params["tls_verify"]? || ENV["DOCKER_TLS_VERIFY"]?)
        return nil unless docker_host.starts_with?("https://") || validate || flag?(params["tls"]? || ENV["DOCKER_TLS"]?)

        cacert_path, cert_path, key_path = cert_paths(params)
        context = OpenSSL::SSL::Context::Client.new
        context.ca_certificates = cacert_path if cacert_path
        context.certificate_chain = cert_path if cert_path
        context.private_key = key_path if key_path
        context.verify_mode = validate ? OpenSSL::SSL::VerifyMode::PEER : OpenSSL::SSL::VerifyMode::NONE
        context
      end

      # Explicit cacert_path:/cert_path:/key_path: params win outright;
      # only when *none* of the three is given does DOCKER_CERT_PATH's
      # own ca.pem/cert.pem/key.pem convention kick in, matching real
      # Ansible's own documented behavior (verified against its source).
      private def self.cert_paths(params : Hash(String, String)) : {String?, String?, String?}
        cacert_path = params["cacert_path"]?
        cert_path = params["cert_path"]?
        key_path = params["key_path"]?
        return {cacert_path, cert_path, key_path} if cacert_path || cert_path || key_path

        cert_dir = ENV["DOCKER_CERT_PATH"]?
        return {nil, nil, nil} unless cert_dir

        {File.join(cert_dir, "ca.pem"), File.join(cert_dir, "cert.pem"), File.join(cert_dir, "key.pem")}
      end

      private def self.flag?(value : String?) : Bool
        !!value && ["true", "yes", "1", "on"].includes?(value.downcase)
      end
    end
  end
end

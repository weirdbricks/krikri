require "docr"
require "openssl"
require "./docker_sdk_error"
require "./python_lib_gate"

module Krikri
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
      # Engine API directly (docr) and needs no `requests` either, so
      # without this gate it carried on where real stops.
      #
      # Runs at the same point real's does: after TLS parameter validation,
      # before the client is constructed, so before any network I/O.
      # Memoized per plugin process (one task = one process).
      @@gate_checked = false

      def self.sdk_import_gate : Nil
        return if @@gate_checked
        @@gate_checked = true
        return unless gate = Krikri.missing_python_library("requests", "requests")
        raise SdkImportGateError.new(gate[:msg], gate[:detail])
      end

      # Clears the per-process memoization above - the specs run several
      # gate calls in ONE process, where a task gets a fresh process each.
      def self.reset_sdk_import_gate : Nil
        @@gate_checked = false
      end

      def self.build(params : Hash(String, String)) : {Docr::Client, String}
        docker_host = resolved_docker_host(params)

        if docker_host && (docker_host.starts_with?("tcp://") || docker_host.starts_with?("https://") || docker_host.starts_with?("http://"))
          build_tcp(params, docker_host)
        else
          socket_path = docker_host.try(&.sub(/^unix:\/\//, ""))
          sdk_import_gate
          client = Docr::Client.new(socket_path)
          {client, socket_path || "default socket #{Docr::Client::DEFAULT_SOCKET_PATH}"}
        end
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

      private def self.build_tcp(params : Hash(String, String), docker_host : String) : {Docr::Client, String}
        uri = URI.parse(docker_host)
        host = uri.host || raise "docker_host: '#{docker_host}' is missing a hostname"
        port = uri.port || 2376
        tls_hostname = params["tls_hostname"]? || env_overlay(params)["DOCKER_TLS_HOSTNAME"]? || ENV["DOCKER_TLS_HOSTNAME"]?

        tls = build_tls_context(params, docker_host)
        sdk_import_gate
        client = Docr::Client.new(host, port, tls, tls_hostname)
        {client, "#{docker_host}#{tls ? " (TLS)" : ""}"}
      end

      # nil (plain TCP, no TLS at all) unless docker_host: is https://
      # or tls:/validate_certs: was explicitly given (as a param or via
      # DOCKER_TLS/DOCKER_TLS_VERIFY) - see the class doc comment above
      # for why cert paths alone deliberately do NOT trigger this.
      private def self.build_tls_context(params : Hash(String, String), docker_host : String) : OpenSSL::SSL::Context::Client?
        overlay = env_overlay(params)
        return nil unless tls_requested?(params, docker_host, overlay)
        validate = flag?(params["validate_certs"]? || params["tls_verify"]? || overlay["DOCKER_TLS_VERIFY"]? || ENV["DOCKER_TLS_VERIFY"]?)

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
      private def self.tls_requested?(params : Hash(String, String), docker_host : String, overlay : Hash(String, String)) : Bool
        return true if docker_host.starts_with?("https://")
        return true if flag?(params["tls"]? || overlay["DOCKER_TLS"]? || ENV["DOCKER_TLS"]?)

        flag?(params["validate_certs"]? || params["tls_verify"]? || overlay["DOCKER_TLS_VERIFY"]? || ENV["DOCKER_TLS_VERIFY"]?)
      end

      # Explicit cacert_path:/cert_path:/key_path: params win outright;
      # only when *none* of the three is given does DOCKER_CERT_PATH's
      # own ca.pem/cert.pem/key.pem convention kick in, matching
      # Ansible's own documented behavior (verified against its source).
      private def self.cert_paths(params : Hash(String, String)) : {String?, String?, String?}
        cacert_path = params["cacert_path"]?
        cert_path = params["cert_path"]?
        key_path = params["key_path"]?
        return {cacert_path, cert_path, key_path} if cacert_path || cert_path || key_path

        cert_dir = env_overlay(params)["DOCKER_CERT_PATH"]? || ENV["DOCKER_CERT_PATH"]?
        return {nil, nil, nil} unless cert_dir

        {File.join(cert_dir, "ca.pem"), File.join(cert_dir, "cert.pem"), File.join(cert_dir, "key.pem")}
      end

      private def self.flag?(value : String?) : Bool
        !!value && ["true", "yes", "1", "on"].includes?(value.downcase)
      end
    end
  end
end

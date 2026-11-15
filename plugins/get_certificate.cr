#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/x509_cert_info"
require "../src/krikri/plugin_helpers/python_lib_gate"
require "../src/krikri/plugin_helpers/socket_connect"

module Krikri
  # get_certificate plugin (community.crypto.get_certificate) - connects
  # to host:port over TLS, retrieves the certificate the server presents,
  # and reports its facts (subject/issuer/validity/extensions/
  # fingerprints) through the shared X509CertInfo helper. The Ansible module
  # writes nothing to disk and never changes state - the cert is only
  # returned in the `cert` fact (earlier revisions here invented a
  # `path:` writing feature the Ansible module does not have).
  #
  # Params (the Ansible module's argument_spec, no aliases): host, port
  # (both required), ca_cert (verifies the chain against a PEM file - the
  # Ansible module's caveat applies: this checks the chain, not that the
  # cert is valid for the host), server_name (SNI, defaults to host),
  # timeout, proxy_host/proxy_port (the TCP hop goes to the proxy pair,
  # proxy_port defaulting to 8080 like the Ansible module), starttls
  # (mysql), ciphers, asn1_base64, tls_ctx_options, select_crypto_backend
  # (accepted; only the OpenSSL CLI path is implemented),
  # get_certificate_chain (the unverified chain comes from the same
  # connection; verified_chain is not implemented - see KNOWN_MISSING.md).
  #
  # AnsibleModule validation order is mirrored: required -> types
  # (spec declaration order) -> choices -> unsupported (deferred last).
  class GetCertificatePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    SPEC = {
      "ca_cert"               => [] of String,
      "host"                  => [] of String,
      "port"                  => [] of String,
      "proxy_host"            => [] of String,
      "proxy_port"            => [] of String,
      "server_name"           => [] of String,
      "timeout"               => [] of String,
      "select_crypto_backend" => [] of String,
      "starttls"              => [] of String,
      "ciphers"               => [] of String,
      "asn1_base64"           => [] of String,
      "tls_ctx_options"       => [] of String,
      "get_certificate_chain" => [] of String,
    }

    # Live-verified against ansible-core 2.19.11 (community.crypto
    # 3.1.1) via `{{ r | to_json }}` dumps against a local TLS server:
    # changed leads, cert follows, then the parsed info keys, then
    # verified_chain/unverified_chain (only with
    # get_certificate_chain). ansible_facts is controller-added,
    # warnings trails last.
    SUCCESS_KEY_ORDER = %w[
      changed cert subject expired extensions issuer not_after not_before
      serial_number signature_algorithm version verified_chain
      unverified_chain ansible_facts failed warnings
    ]

    # The parsed-info keys Ansible's result dict actually carries
    # (get_certificate.py's own result assembly). X509CertInfo.parse
    # serves the wider x509_certificate_info vocabulary too
    # (fingerprints, public_key*, key_usage, subject_alt_name, ...);
    # merging all of it gave get_certificate's result a dozen keys real
    # never returns - only these pass through.
    RESULT_INFO_KEYS = %w[
      subject expired extensions issuer not_after not_before
      serial_number signature_algorithm version
    ]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      # get_certificate.py passes no supports_check_mode=True to its
      # AnsibleModule, so basic.py's own gate (which sits AFTER argument
      # validation, unlike an action plugin's) exits with a skip instead
      # of ever connecting - live-verified vs 2.21.6: under --check the
      # module skips with this msg while an invalid port still fails
      # validation. The skip therefore also wins over the ca_cert
      # existence check that lives in the module body. Without the gate
      # this plugin made the real connection under --check and reported a
      # failure ansible never had, which also turned a following
      # `when: r is not skipped` task from skipped into a run (kpg issues
      # #1312, #1314).
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.crypto.get_certificate"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true,
          omit_changed: true, key_order: ["skipped", "msg"])
      end

      host = @params["host"]
      port = @params["port"].to_i

      # Ansible's main() order: the get_certificate_chain Python-version
      # gate, then assert_required_cryptography_version, then the
      # timeout, then the ca_cert existence check - all BEFORE the
      # connection attempt (live-verified vs 2.19.11).
      get_certificate_chain = true?(@params["get_certificate_chain"]?)
      if (python = target_python) && get_certificate_chain
        if pyver = python_version(python)
          return failure("get_certificate_chain=true can only be used with Python 3.10 (Python 3.13+ officially supports this). " \
                         "The Python version used to run the get_certificate module is #{python_full_version(python)}") if pyver < {3, 10}
        end
        unless cryptography_available?(python)
          return failure(missing_required_lib_msg("cryptography >= 3.3", python))
        end
      end

      return failure("ca_cert file does not exist") if (ca_cert = @params["ca_cert"]?) && !File.exists?(expand_tilde(ca_cert))

      sni = @params["server_name"]? || host
      proxy_host = @params["proxy_host"]?
      proxy_port = @params["proxy_port"]?.try(&.to_i) || 8080

      # Real applies the module's `timeout` (default 10) as
      # setdefaulttimeout() to every socket operation it then makes, so a
      # target the kernel never answers fails with TimeoutError("timed
      # out") once that deadline expires. `timeout: 0` is falsy for the
      # module's `if timeout:`, leaving Python's no-timeout default in
      # place. Without this deadline the connect below blocked until the
      # kernel's own SYN retries gave up (minutes), long after the
      # playbook (and the generator's round) had moved on.
      timeout_seconds = @params["timeout"]?.try(&.to_i) || 10
      timeout = timeout_seconds > 0 ? timeout_seconds.seconds : nil

      # Real connects natively (socket.create_connection, or an explicit
      # socket() + HTTP CONNECT hop when proxy_host is set) and wraps ANY
      # connection exception in the same fail_json: its `error: {e}` tail
      # is the raw Python exception text (gaierror/OSError/timeout shapes).
      pems, conn_error = fetch_certs(host, port, sni, ca_cert.try { |value| expand_tilde(value) }, proxy_host, proxy_port, timeout)
      if err = conn_error
        return failure(proxy_host ? "Failed to get cert via proxy #{proxy_host}:#{proxy_port} from #{host}:#{port}, error: #{err}" : "Failed to get cert from #{host}:#{port}, error: #{err}")
      end
      return failure("Failed to get cert from #{host}:#{port}, error: Unexpected error: no peer certificate has been returned") if !pems || pems.empty?
      cert_pem = pems.first

      info = X509CertInfo.parse(cert_pem)
      return failure("Unable to parse the retrieved certificate") unless info

      res = PluginResult.new(changed: false, failed: false, msg: "", key_order: SUCCESS_KEY_ORDER)
      info.each do |key, value|
        next unless RESULT_INFO_KEYS.includes?(key)
        res.extra[key] = value
      end
      res.extra["cert"] = JSON::Any.new(cert_pem)
      if get_certificate_chain && pems.size > 1
        res.extra["unverified_chain"] = JSON::Any.new(pems.map { |pem| JSON::Any.new(pem) })
      end
      res
    end

    # AnsibleModule validation order: required -> types (spec
    # declaration order) -> choices -> unsupported (deferred last).
    private def validate_arguments : PluginResult?
      missing = %w[host port].select { |param| @params[param]?.nil? }
      return missing_required_error(missing) unless missing.empty?

      {"port" => :int, "proxy_port" => :int, "timeout" => :int,
       "asn1_base64" => :bool, "get_certificate_chain" => :bool}.each do |param, type|
        next unless raw = @params[param]?
        if type == :int
          next if raw.to_i32?
          return int_type_error(param, raw)
        else
          next if bool_convertible?(raw)
          return bool_type_error(param, raw)
        end
      end

      backend = @params["select_crypto_backend"]? || "auto"
      unless %w[auto cryptography].includes?(backend)
        return choices_error("select_crypto_backend", %w[auto cryptography], backend)
      end
      if (starttls = @params["starttls"]?) && starttls != "mysql"
        return choices_error("starttls", %w[mysql], starttls)
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.get_certificate", unsupported, SPEC)
      end
      nil
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # The interpreter Ansible's module would run under (the discovered one):
    # the first existing python3/python, resolved to its realpath the way
    # interpreter discovery reports it (/usr/bin/python3.13-style).
    private def target_python : String?
      %w[python3 python].each do |interpreter|
        next unless Process.find_executable(interpreter)
        io = IO::Memory.new
        status = Process.run(interpreter, {"-c", "import os, sys; print(os.path.realpath(sys.executable))"},
          output: io, error: Process::Redirect::Close)
        return io.to_s.strip if status.success?
      end
      nil
    end

    private def python_version(python : String) : Tuple(Int32, Int32)?
      io = IO::Memory.new
      status = Process.run(python, {"-c", "import sys; print(sys.version_info[0], sys.version_info[1])"},
        output: io, error: Process::Redirect::Close)
      return nil unless status.success?
      parts = io.to_s.strip.split
      {parts[0].to_i, parts[1].to_i} if parts.size == 2
    end

    private def python_full_version(python : String) : String
      io = IO::Memory.new
      status = Process.run(python, {"-c", "import sys; print(sys.version)"}, output: io, error: Process::Redirect::Close)
      status.success? ? io.to_s.strip : ""
    end

    private def cryptography_available?(python : String) : Bool
      io = IO::Memory.new
      probe = "import cryptography\n" \
              "parts = cryptography.__version__.split('.')\n" \
              "print('yes' if (int(parts[0]), int(parts[1])) >= (3, 3) else 'no')"
      status = Process.run(python, {"-c", probe}, output: io, error: Process::Redirect::Close)
      status.success? && io.to_s.strip == "yes"
    end

    # The shared missing_required_lib message (python_lib_gate.cr).
    private def missing_required_lib_msg(library : String, python : String) : String
      Krikri.missing_required_lib_message("#{library}", python)
    end

    # The connection attempt, real-shaped: a native TCP connect (through
    # the proxy pair when proxy_host is set) reproduces Python's own
    # failure texts - a getaddrinfo failure becomes the gaierror
    # "[Errno -N] <gai_strerror>", a refused/unreachable hop the
    # OSError "[Errno N] <strerror>", and a hop the kernel never answers
    # the bare "timed out" of Python's TimeoutError. On success the
    # certificate chain is still collected through the `openssl s_client`
    # CLI (the module's TLS specifics - SNI, CA verification - apply to
    # the second connection the same way).
    private def fetch_certs(host : String, port : Int32, sni : String, ca_cert : String?,
                            proxy_host : String?, proxy_port : Int32,
                            timeout : Time::Span?) : {Array(String)?, String?}
      connect_host = proxy_host || host
      connect_port = proxy_host ? proxy_port : port
      error = probe_tcp(connect_host, connect_port, timeout)
      return {nil, error} if error

      {s_client_certs(host, port, sni, ca_cert, proxy_host ? "#{proxy_host}:#{proxy_port}" : nil, timeout), nil}
    rescue IO::TimeoutError
      {nil, "timed out"}
    end

    # One native TCP connect with Python's error classification, under the
    # module's timeout: the getaddrinfo failure (gaierror) short-circuits
    # exactly like Ansible's create_connection, resolution hits are tried in
    # order until one connects, and a connect still in flight at the
    # deadline raises TimeoutError - whose str() is the bare "timed out"
    # Ansible's message carries.
    private def probe_tcp(host : String, port : Int32, timeout : Time::Span?) : String?
      PluginHelpers::SocketConnect.open(host, port, timeout).close
      nil
    rescue IO::TimeoutError
      "timed out"
    rescue ex : Socket::Addrinfo::Error
      dns_error_text(ex)
    rescue ex : Socket::ConnectError
      errno = ex.os_error.as?(Errno)
      errno ? oserror_text(errno.value) : (ex.message || "unknown error")
    end

    # Python socket.gaierror's str(), from the negative EAI_* code Crystal's
    # getaddrinfo failure carries in os_error.
    private def dns_error_text(ex : Socket::Addrinfo::Error) : String
      code = ex.os_error.as?(Errno).try(&.value.to_i32)
      return ex.message || "unknown error" unless code && code < 0
      gaierror_text(code)
    end

    # Python socket.gaierror's str(), glibc's gai_strerror texts.
    private def gaierror_text(code : Int32) : String
      reason = case code
               when LibC::EAI_NONAME   then "Name or service not known"
               when LibC::EAI_AGAIN    then "Temporary failure in name resolution"
               when LibC::EAI_FAIL     then "Non-recoverable failure in name resolution"
               when LibC::EAI_NODATA   then "No address associated with hostname"
               when LibC::EAI_FAMILY   then "Address family not supported by protocol"
               when LibC::EAI_SOCKTYPE then "Ai_socktype not supported"
               when LibC::EAI_SERVICE  then "Servname not supported for ai_socktype"
               when LibC::EAI_MEMORY   then "Memory allocation failure"
               when LibC::EAI_SYSTEM   then "System error"
               when LibC::EAI_OVERFLOW then "Argument buffer overflow"
               else                         "Unknown error"
               end
      "[Errno #{code}] #{reason}"
    end

    # Python OSError's str() for a connect errno: "[Errno N] <strerror>".
    private def oserror_text(errno : Int32 | UInt16 | UInt32) : String
      "[Errno #{errno}] #{Errno.from_value(errno.to_i32).message}"
    end

    # s_client prints the server's chain (leaf first) as PEM blocks on
    # stdout. With ca_cert the connection additionally demands a chain
    # that verifies against that store (the Ansible module's validation
    # scope: the chain, not the hostname). With proxy_host the TCP hop
    # goes through an HTTP CONNECT proxy (s_client -proxy). The run is
    # bounded by the module's timeout the same way the TCP connect is, so a
    # server that accepts and then stalls still fails instead of hanging the
    # task forever. (Python fails the stalled handshake at that same
    # deadline, but the text it carries is CPython's own
    # "_ssl.c:<line>: The handshake operation timed out", whose file:line
    # belongs to the target's Python build and cannot be reproduced here.)
    private def s_client_certs(host : String, port : Int32, sni : String, ca_cert : String?,
                               proxy : String?, timeout : Time::Span?) : Array(String)?
      args = ["s_client", "-connect", "#{host}:#{port}", "-servername", sni]
      args << "-proxy" << proxy if proxy
      args << "-verify_return_error" << "-CAfile" << ca_cert if ca_cert
      output = IO::Memory.new
      process = Process.new("openssl", args, input: Process::Redirect::Close, output: output,
        error: Process::Redirect::Close)
      status = wait_with_deadline(process, timeout)
      raise IO::TimeoutError.new("timed out") unless status
      return nil if !status.success? && output.to_s.empty?

      certs = [] of String
      scanner = output.to_s
      while start = scanner.index("-----BEGIN CERTIFICATE-----")
        stop = scanner.index("-----END CERTIFICATE-----", start)
        break unless stop
        certs << scanner[start..stop + "-----END CERTIFICATE-----".size] + "\n"
        scanner = scanner[(stop + 25)..]
      end
      certs.empty? ? nil : certs
    end

    # Waits for `process`, killing it (and reporting nil) when it outlives
    # `timeout`. A nil timeout waits forever, matching Python's own
    # no-timeout default.
    private def wait_with_deadline(process : Process, timeout : Time::Span?) : Process::Status?
      return process.wait unless timeout

      finished = Channel(Process::Status).new(1)
      spawn do
        finished.send(process.wait)
      end
      select
      when status = finished.receive
        status
      when timeout(timeout)
        process.signal(Signal::KILL)
        nil
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::GetCertificatePlugin.new(config)
plugin.run

require "openssl"
require "./python_lib_gate"

module Krikri
  module PluginHelpers
    # URLPreflight - the failures real Ansible's fetch_url reports BEFORE
    # urllib ever opens the URL, shared by the uri and get_url plugins.
    #
    # Real Ansible builds a request in three steps that all happen before
    # a single byte goes out (the real module's Request.open, 2.19.11):
    #
    #   1. _configure_auth() - with use_gssapi: true the module imports
    #      python-gssapi, and a host without it raises MissingModuleError
    #      (fetch_url's own `except MissingModuleError` handler, whose
    #      result carries the message ALONE - no url, no status).
    #   2. make_context() - opens ca_path (ssl.create_default_context's
    #      cafile=), applies ciphers: (set_ciphers on the joined list) and
    #      loads client_cert:/client_key: (load_cert_chain). A missing or
    #      unusable file raises an OSError, an unusable cipher list an
    #      SSLError; both are OSError subclasses, so fetch_url's
    #      `except OSError` handler folds them into
    #      info['msg'] = "Connection failure: <str(ex)>" with status -1.
    #   3. urllib.request.Request(url) - a URL with no type at all raises
    #      ValueError("unknown url type: '<url>'"), which fetch_url
    #      re-raises through fail_json(msg=..., **info) with
    #      info = {url, status: -1}. A URL that DOES have a type but no
    #      handler (gopher://..., "127.0.0.1:80/x" - Python's type split
    #      does not require an RFC scheme) instead dies later, in
    #      urllib's own UnknownHandler, with
    #      URLError('unknown url type: <type>') - so it comes back as
    #      info['msg'] = "Request failed: <urlopen error unknown url
    #      type: <type>>" with status -1, i.e. the same info dict the
    #      OSError half below produces.
    #
    # The order matters as much as the checks: make_context runs before
    # the URL is parsed, so a task carrying BOTH a bogus ciphers: list and
    # a scheme-less url reports the cipher failure. Each module's own
    # module-side logic (get_url's dest/checksum skip, uri's
    # creates:/removes: skip) runs even earlier - see the call sites.
    #
    # Deliberately NOT emulated: the content-level OpenSSL errors a
    # non-PEM (or empty) ca_path/client_cert raises ("[SSL] PEM lib
    # (_ssl.c:4093)", "[X509: NO_CERTIFICATE_OR_CRL_FOUND] ...") - those
    # carry CPython source line numbers and vary per interpreter build,
    # so matching them would be guesswork. A readable file of any content
    # passes the preflight and fails (or works) at handshake time, exactly
    # as the real request would.
    module URLPreflight
      # How the calling module has to shape its own result around the
      # message - the three handlers above do NOT produce the same keys.
      enum Kind
        # MissingModuleError: {changed: false, msg} and nothing else.
        MissingLibrary
        # fetch_url's info dict for an OSError: the caller formats its own
        # module-level message around "Connection failure: ..." and adds
        # url/dest/elapsed (get_url) or url/status/elapsed/redirected/
        # content (uri) - see the call sites.
        ConnectionFailure
        # ValueError from urllib: {msg, url, status: -1}.
        UnknownUrlType
        # URLError from urllib's UnknownHandler: a URL that HAS a type
        # no default handler serves (gopher://..., "127.0.0.1:80/x") is
        # not a Request-construction failure - the request object builds
        # fine and dies at open() - so it arrives as info['msg'] with
        # status -1, the same dict the OSError half above produces.
        UnknownUrlScheme
      end

      record Failure, kind : Kind, msg : String

      # The URL types urllib's default opener actually has a handler
      # for (urllib.request's own default handler list).
      URL_TYPES = %w(http https ftp file data)

      # The `ciphers` is the OpenSSL cipher-list string the real params join
      # into ("all ciphers are joined in order with ':'", get_url's own
      # docs) - nil or empty means "don't set them", in which case real
      # Ansible skips set_ciphers entirely.
      def self.check(
        url : String,
        ciphers : String? = nil,
        ca_path : String? = nil,
        client_cert : String? = nil,
        client_key : String? = nil,
        use_gssapi : Bool = false,
      ) : Failure?
        if use_gssapi
          gssapi_failure.try { |failure| return failure }
        end

        # make_context's own order: cafile first, then the cipher list,
        # then the client certificate chain.
        context_failure(ca_path, ciphers, client_cert, client_key).try { |failure| return failure }

        if type = url_type(url)
          unless URL_TYPES.includes?(type)
            return Failure.new(Kind::UnknownUrlScheme, "Request failed: <urlopen error unknown url type: #{type}>")
          end
        else
          return Failure.new(Kind::UnknownUrlType, "unknown url type: '#{url}'")
        end

        nil
      end

      # Python's own type split - urllib.request._splittype's
      # `([^/:]+):` - returns everything up to the first colon, whatever
      # it is made of (it does NOT require an RFC scheme, so
      # "127.0.0.1:80/x" types as "127.0.0.1"), or nil when the URL
      # carries no colon at all. nil is the ValueError half of the two
      # unknown-URL-type failures (Request's own _parse), a type no
      # handler serves is the URLError half (UnknownHandler).
      private def self.url_type(url : String) : String?
        head, separator, _ = url.partition(":")
        return nil if separator.empty?
        return nil if head.empty? || head.includes?("/")
        head.downcase
      end

      # The _configure_auth half: use_gssapi: on a host whose python cannot
      # import gssapi. A python that vanished between the two probes (or
      # refuses to run at all) must not crash the task - real's own
      # message needs an interpreter path to be worth anything, so with
      # none found the check simply passes.
      private def self.gssapi_failure : Failure?
        python = python_interpreter
        return nil unless python
        begin
          probe = Process.run(python, {"-c", "import gssapi"}, error: Process::Redirect::Close)
          return nil if probe.success?
        rescue
          return nil
        end
        missing_library_failure(python)
      end

      # The make_context half, in its own order: cafile (its own open),
      # then set_ciphers, then load_cert_chain. The cipher list is
      # applied BEFORE the client certificate chain is loaded
      # (ansible-core 2.19.11's the real module make_context), so a
      # task carrying BOTH a garbage ciphers: list and a
      # client_cert:/client_key: that do not exist reports the cipher
      # failure, not the missing file - live-verified vs 2.19.11 on
      # get_url with ciphers: [yrsmlh, uajhkq, dygslx] plus
      # client_cert: /tmp/kpg-work/out3.cfg (absent): "Connection
      # failure: ('No cipher can be selected.',)", and with the same
      # missing client_cert but a real cipher name: "Connection failure:
      # [Errno 2] No such file or directory". Checking the chain first
      # reported the file error for both (kpg31 sweep sigs 3a256df85682
      # and 7c51dac085e3, get_url and uri).
      private def self.context_failure(ca_path, ciphers, client_cert, client_key) : Failure?
        if ca_path
          file_error(ca_path).try { |error| return connection_failure(error) }
        end

        if ciphers && !ciphers.empty? && !ciphers_select_anything?(ciphers)
          return connection_failure("('No cipher can be selected.',)")
        end

        # client_key is only ever read as load_cert_chain's keyfile=, and
        # that call only happens when client_cert is given - a task with a
        # client_key alone has its file never opened by real Ansible
        # (live-verified vs 2.19.11: get_url with only a missing client_key:
        # still reaches the request).
        chain_files = client_cert ? [client_cert, client_key] : [] of String?
        chain_error = chain_files.each do |path|
          next unless path
          if error = file_error(path)
            break connection_failure(error)
          end
        end
        return chain_error if chain_error

        nil
      end

      # Real Ansible's own missing_required_lib wording (basic.py's
      # _handle_missing_required_lib), the same shape nsupdate.cr and
      # aws_module_args.cr already emit for gssapi and boto3: the
      # hostname, the interpreter the module would have run under, the
      # reason and the doc URL.
      private def self.missing_library_failure(python : String) : Failure
        Failure.new(Kind::MissingLibrary,
          Krikri.missing_required_lib_message("gssapi", python, "This is required for use_gssapi=True. See https://pypi.org/project/gssapi/ for more info."))
      end

      private def self.connection_failure(error : String) : Failure
        Failure.new(Kind::ConnectionFailure, "Connection failure: #{error}")
      end

      # str(OSError) for the file-level failures the two OpenSSL entry
      # points raise. Anything readable is passed through to the real
      # request (see this module's comment on content-level errors).
      private def self.file_error(path : String) : String?
        return nil if File.file?(path) && File::Info.readable?(path)
        return "[Errno 21] Is a directory" if File.directory?(path)
        return "[Errno 13] Permission denied" if File.exists?(path)
        "[Errno 2] No such file or directory"
      end

      # SSL_CTX_set_cipher_list's own verdict, asked through the same
      # libssl the target's python would ask: python's ssl module raises
      # SSLError("No cipher can be selected.") when the call selects
      # nothing, Crystal raises OpenSSL::Error with libssl's own (much
      # more specific, and version-dependent) message - only the verdict
      # needs to agree, the text is Python's. Verified to agree with
      # python 3.13 on garbage names, TLS1.3-only names and real OpenSSL
      # cipher strings alike.
      private def self.ciphers_select_anything?(ciphers : String) : Bool
        context = OpenSSL::SSL::Context::Client.new
        context.ciphers = ciphers
        true
      rescue
        false
      end

      # Real Ansible runs the module under the interpreter it discovered
      # for the host; aws_module_args.cr's boto3 gate asks python3 for
      # its own sys.executable the same way, and that is the path real
      # Ansible's message quotes.
      private def self.python_interpreter : String?
        ["python3", "python"].each do |name|
          io = IO::Memory.new
          # Process.run RAISES (rather than reporting a non-zero status)
          # for a name the PATH cannot resolve, and a target with only
          # python3 must not die on the second attempt.
          status = begin
            Process.run(name, {"-c", "import sys; print(sys.executable)"},
              output: io, error: Process::Redirect::Close)
          rescue
            next
          end
          path = io.to_s.strip
          return path if status.success? && !path.empty?
        end
        nil
      end
    end
  end
end

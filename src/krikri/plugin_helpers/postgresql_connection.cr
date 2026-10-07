require "uri"
require "socket"

{% if flag?(:linux) && !LibC.has_constant?("Pollfd") && !LibC.has_method?(:poll) %}
  # poll(2) is not in Crystal's Linux LibC bindings (the event loop uses
  # epoll) - bound here just for the bounded probe connect below, guarded
  # so it never clashes with another declaration of the same C symbol in
  # the same compilation unit (plugins/expect.cr already declares both in
  # the fat plugin build). Declared at top level, like expect.cr's - a
  # module-scoped lib would shadow top-level LibC inside this module and
  # hide every constant the netdb bindings add. nfds_t is unsigned long
  # on Linux.
  lib LibC
    struct Pollfd
      fd : Int32
      events : Int16
      revents : Int16
    end

    fun poll(fds : Pollfd*, nfds : UInt64, timeout : Int32) : Int32
  end
{% end %}

require "json"

module Krikri
  module PluginHelpers
    # PostgresqlConnection - pure logic for building a postgres://
    # connection URI from Ansible-style login_* params. No I/O -
    # postgresql_db.cr/postgresql_user.cr do the actual DB.open.
    module PostgresqlConnection
      # libpq's wording for a connection the server accepted and then
      # dropped before/during startup packet exchange (both a clean
      # close and an RST - live-verified against ansible-core 2.19.11 +
      # community.postgresql 4.2.0: SO_LINGER-0 RST on the accepted
      # socket reports this same text, no "Is the server running..."
      # hint line either). Ends with its own newline, like libpq's
      # PQerrorMessage buffer always does.
      SERVER_CLOSED_TEXT =
        "server closed the connection unexpectedly\n" \
        "\tThis probably means the server terminated abnormally\n" \
        "\tbefore or while processing the request.\n"

      # unix_socket, given, takes precedence over host/port (matches
      # Ansible's postgresql_db/postgresql_user own login_unix_socket
      # precedence). crystal-pg expects a unix socket path via a "host"
      # query param, not the URI's own host component (verified against
      # its actual conninfo parsing source, not assumed) - the URI host
      # is left blank in that case.
      # Debian/Ubuntu's postgresql-common packaging (the target of every
      # real-host benchmark round so far) compiles libpq's default Unix
      # socket directory to this path - matches `postgresql.conf`'s own
      # `unix_socket_directories` default there.
      DEFAULT_UNIX_SOCKET_DIR = "/var/run/postgresql"

      # libpq's connect_timeout: the whole connect sequence - TCP
      # connect, SSL negotiation, startup packet exchange, auth - is
      # bounded; on expiry libpq words the failure "timeout expired"
      # (fe-connect.c's connect-timeout handling; the sentence libpq
      # prints is
      #   connection to server at "H", port N failed: timeout expired
      # with NO "Is the server running..." hint line, unlike the errno
      # path - UNVERIFIED against real ansible until checked on a real
      # host). Both of community.postgresql's ways to set it are
      # honored, in libpq's own precedence order (PGCONNECT_TIMEOUT is
      # consulted only when the conninfo keyword is absent):
      # - the module's own integer `connect_timeout:` param;
      # - PGCONNECT_TIMEOUT in the module's process environment (the
      #   gateway to libpq's built-in default - libpq's default when
      #   neither is set is a plain 2-minute OS connect timeout, so
      #   neither set means unbounded and no DB-level bound is applied).
      # crystal-pg itself has no connect timeout (its ConnInfo parses no
      # such key and PQ::Connection#initialize connects unboundedly), so
      # the connect attempt is bounded instead: DB.open only fails with
      # DB::ConnectionRefused (from PG::Connection#initialize wrapping
      # whatever PQ::Connection raised) while the pool's initial
      # connection is built, so a ConnectionRefused whose cause carries
      # the deadline marker means the deadline, not the socket, expired.
      # Only the connection attempt is bounded: the module block (the
      # queries) runs on the connected database afterwards, outside the
      # deadline, so a slow query can never be misreported as a connect
      # timeout.

      # Exception cause marker used to detect an expiry-caused
      # ConnectionRefused at the plugin rescue sites (where the raw
      # params hash is available for the target text). Nested, not
      # raised directly, so it can only ever be present through this
      # module's own timeout path.
      class ConnectTimeoutCause < ::Exception
        def initialize(@timeout : Time::Span)
          super("timeout expired")
        end

        getter timeout : Time::Span
      end

      # Resolves the effective connect timeout for a module run, the two
      # ways community.postgresql lets one be set (it has no top-level
      # `connect_timeout` option): `connect_params: {connect_timeout: N}`
      # first, then PGCONNECT_TIMEOUT. Nil = unbounded (no DB-level
      # deadline).
      def self.connect_timeout(params : Hash(String, String)) : Time::Span?
        if raw = params["connect_params"]?
          if (dict = (JSON.parse(raw).as_h? rescue nil)) && (value = dict["connect_timeout"]?)
            seconds = value.as_i? || value.as_s?.try(&.to_i?)
            return seconds.seconds if seconds && seconds > 0
          end
        end
        if raw = task_pgconnect_timeout(params) || ENV["PGCONNECT_TIMEOUT"]?
          return raw.to_i.seconds if (n = raw.to_i?) && n > 0
        end
        nil
      end

      # PGCONNECT_TIMEOUT from the task's `environment:` keyword. It
      # reaches the plugin as the `_environment` JSON param, not in the
      # plugin process's own ENV, and - as in Ansible, where the task
      # environment is applied over the module's - it wins over the
      # process environment.
      private def self.task_pgconnect_timeout(params : Hash(String, String)) : String?
        raw = params["_environment"]? || return nil
        value = JSON.parse(raw).as_h?.try(&.["PGCONNECT_TIMEOUT"]?) rescue nil
        value.try { |v| v.as_s? || v.as_i?.try(&.to_s) }
      end

      # DB.open bounded by *timeout* (nil = plain DB.open). Only the
      # connection attempt runs under the deadline - the module block
      # runs on the connected database afterwards, in the caller's
      # fiber, so a slow query is never misreported as a connect
      # timeout. Raises DB::ConnectionRefused (cause:
      # ConnectTimeoutCause) when the deadline expires; a database that
      # finishes connecting after the deadline is closed by the fiber
      # that built it (see #connect_within_deadline), so neither that
      # fiber nor the connection leaks. crystal-db's pool builds its
      # initial connection eagerly inside `DB::Database.new` and, with
      # retry_attempts=0, ConnectionRefused is never retried or
      # swallowed there, so the only connection attempt in flight is
      # the one this bounds.
      def self.open(uri : String, params : Hash(String, String), &block : DB::Database -> _)
        timeout = connect_timeout(params)
        if timeout.nil?
          DB.open(uri) { |db| block.call(db) }
        else
          db = connect_within_deadline(uri, timeout)
          begin
            block.call(db)
          ensure
            db.close
          end
        end
      end

      # The bounded connect attempt itself: `DB.open(uri)` with NO
      # block, run in a spawned fiber under the deadline. Returns the
      # connected database, or raises the deadline-caused
      # DB::ConnectionRefused. The mutex guards the handoff so an
      # expiry landing in the same instant the connect completes still
      # closes the database exactly once - either the fiber sees the
      # expiry first and closes the database itself, or it hands it
      # over and the deadline branch closes it.
      private def self.connect_within_deadline(uri : String, deadline : Time::Span) : DB::Database
        mutex = Mutex.new
        expired = false
        handed_off : DB::Database? = nil
        failure : DB::ConnectionRefused? = nil
        # When the connect fiber itself failed, the elapsed time at
        # which it failed - the done branch below needs to know whether
        # the failure landed before or after the deadline moment,
        # because real libpq words the two differently (its poll
        # deadline fires at the same instant regardless of what the
        # socket does next).
        failed_at : Time::Span? = nil
        # Buffered: the fiber must never block on signaling a result
        # the caller already gave up on (the expired path).
        done = Channel(Nil).new(1)
        started = Time.instant

        spawn do
          begin
            db = DB.open(uri)
            mutex.synchronize do
              if expired
                db.close
              else
                handed_off = db
              end
            end
          rescue ex : DB::ConnectionRefused
            at = Time.instant - started
            mutex.synchronize do
              failure = ex
              failed_at = at
            end
          rescue ex : Exception
            # crystal-pg wraps every connect-stage failure; anything
            # not already a ConnectionRefused becomes one, keeping the
            # plugins' single rescue type intact.
            at = Time.instant - started
            mutex.synchronize do
              failure = DB::ConnectionRefused.new(cause: ex)
              failed_at = at
            end
          ensure
            done.send(nil)
          end
        end

        select
        when done.receive
          if ex = failure
            # A connect-stage failure that lands at or after the
            # deadline moment is worded as the deadline expiry: real
            # libpq's poll deadline fires at that same instant, before
            # the socket's own error can ever be observed (its wording
            # for that is "timeout expired", no hint line). Before the
            # deadline the socket error is real and keeps the errno
            # wording.
            at = failed_at
            raise DB::ConnectionRefused.new(cause: ConnectTimeoutCause.new(deadline)) if at && at >= deadline
            raise ex
          end
          mutex.synchronize { handed_off.not_nil! }
        when timeout(deadline)
          mutex.synchronize do
            expired = true
            handed_off.try(&.close)
            handed_off = nil
          end
          raise DB::ConnectionRefused.new(cause: ConnectTimeoutCause.new(deadline))
        end
      end

      private def self.new_uri(unix_socket : String?, host : String?, port : String?, path : String) : URI
        if unix_socket
          URI.new(scheme: "postgres", path: path)
        else
          URI.new(scheme: "postgres", host: host || "localhost", port: (port || "5432").to_i, path: path)
        end
      end

      def self.build_uri(
        host : String? = nil,
        port : String? = nil,
        user : String? = nil,
        password : String? = nil,
        unix_socket : String? = nil,
        dbname : String? = nil,
        sslmode : String? = nil,
      ) : String
        path = "/#{dbname || "postgres"}"

        # Real libpq (and psycopg2, which every postgresql_db/
        # postgresql_user real-Ansible run underneath actually uses)
        # defaults to a Unix socket connection - NOT TCP to "localhost"
        # - when no host: is given at all. Real bug found benchmarking
        # robertdebock.postgres (round 43): its own "Create postgres
        # database"/"Create postgres users" tasks never set login_host:,
        # relying on that Unix-socket-by-default behavior (peer auth,
        # matching the task's own become_user: postgres) - this plugin
        # instead always forced a TCP connection to "localhost", which
        # real pg_hba.conf gates behind `ident` (needs a running ident
        # daemon, absent here) rather than the `peer` auth a socket
        # connection gets, so it failed outright ("Could not connect to
        # the PostgreSQL server") while Ansible connected fine.
        unix_socket ||= DEFAULT_UNIX_SOCKET_DIR unless host

        uri = new_uri(unix_socket, host, port, path)

        uri.user = user if user
        uri.password = password if password

        params = URI::Params.new
        params["host"] = unix_socket if unix_socket
        # Only matters for the unix_socket branch (the URI's own `port`
        # already covers the TCP branch) - crystal-pg's socket-directory
        # lookup builds the actual socket filename as `.s.PGSQL.<port>`,
        # so a non-default port (e.g. robertdebock.postgres's own
        # `postgres_port: 6543`) needs to reach it via this query param
        # too, not just the URI's host:port pair.
        params["port"] = port if port && unix_socket
        params["sslmode"] = sslmode if sslmode
        uri.query = params.to_s unless params.to_s.empty?

        uri.to_s
      end

      # The connection target a params hash resolves to, for
      # diagnostics that have to name the server the plugin actually
      # dialed (libpq's connection-error text quotes the host/port or
      # the socket path verbatim). Applies the same defaults
      # #build_uri does: an absent host means a Unix socket in
      # DEFAULT_UNIX_SOCKET_DIR, an absent port means 5432.
      def self.effective_target(params : Hash(String, String)) : {host: String?, port: String, unix_socket: String?}
        login = resolve_login_params(params)
        host = login[:host]
        {
          host:        host,
          port:        login[:port] || "5432",
          unix_socket: login[:unix_socket] || (DEFAULT_UNIX_SOCKET_DIR unless host),
        }
      end

      # libpq's own connection-error wording, which is what real
      # (psycopg2 -> libpq) embeds in community.postgresql's
      # "unable to connect to database: %s" fail_json. Live-verified
      # against ansible-core 2.19.11 + community.postgresql 4.2.0
      # for every case reproduced below:
      #
      # - TCP, nothing listening (ECONNREFUSED):
      #     connection to server at "127.0.0.1", port 59999 failed: Connection refused\n
      #     \tIs the server running on that host and accepting TCP/IP connections?\n
      # - TCP, unroutable netns (ENETUNREACH, `unshare -rn`):
      #     connection to server at "127.0.0.1", port 59999 failed: Network is unreachable\n
      #     \tIs the server running on that host and accepting TCP/IP connections?\n
      # - TCP, blackhole address, natural (unbounded) connect timeout:
      #     connection to server at "192.0.2.1", port 5432 failed: Connection timed out\n
      #     \tIs the server running on that host and accepting TCP/IP connections?\n
      #   (real words a *libpq connect_timeout* expiry differently -
      #   "timeout expired", no hint - when a connect_timeout is set;
      #   krikri models that wording via PostgresqlConnection's own
      #   bounded open, see the module's timeout comment.)
      # - TCP, server accepted the connection and then dropped it (both
      #   a clean close and an SO_LINGER-0 RST on the accepted socket):
      #     connection to server at "127.0.0.1", port 59999 failed: server closed the connection unexpectedly\n
      #     \tThis probably means the server terminated abnormally\n
      #     \tbefore or while processing the request.\n
      # - Unix socket, socket file/dir missing (ENOENT):
      #     connection to server on socket "/nonexistent/sockdir/.s.PGSQL.5432" failed: No such file or directory\n
      #     \tIs the server running locally and accepting connections on that socket?\n
      # - server answered and rejected us (its ErrorResponse carries
      #   the text, so the server-side severity is rebuilt as
      #   "<severity>:  <message>\n", and NO hint line follows):
      #     connection to server at "127.0.0.1", port 35433 failed: FATAL:  password authentication failed for user "postgres"\n
      #     connection to server at "127.0.0.1", port 35433 failed: FATAL:  database "nosuchdb" does not exist\n
      # - unresolvable host (libpq's own DNS wording, no hint line):
      #     could not translate host name "nosuchhost.invalid" to address: Name or service not known\n
      #
      # Reproducible vs not: the errno behind a TCP connect failure is
      # re-derived with a direct non-blocking probe connect at
      # error-report time (see #io_error_detail), because Crystal's
      # Socket::ConnectError misreports the errno ("Resource
      # temporarily unavailable" for a refused connect) and collapses
      # ECONNRESET/ENETUNREACH/ETIMEDOUT into the same exception class.
      # What krikri CANNOT reproduce: a temporary resolver failure,
      # which libpq renders with gai_strerror's "Temporary failure in
      # name resolution" (Crystal's Socket::Addrinfo::Error carries no
      # gai code, so krikri prints the EAI_NONAME wording instead), any
      # strerror string from a non-glibc libc (libpq prints the
      # system's own, locale-dependent strings). The libpq
      # connect_timeout wording ("timeout expired"), formerly in this
      # not-reproducible list, is now modeled - see ConnectTimeoutCause
      # / #libpq_connect_error below.
      def self.libpq_connect_error(ex : DB::ConnectionRefused, target : {host: String?, port: String, unix_socket: String?}, timeout_set : Bool = false) : String
        case cause = unwrap(ex.cause)
        when ConnectTimeoutCause
          # libpq's connect_timeout wording (fe-connect.c), for the
          # connect attempt the deadline killed: no errno was ever
          # seen, so no "Is the server running..." hint line follows
          # (see the timeout comment at the top of this module).
          "#{target_prefix(target)} failed: timeout expired\n"
        when PQ::PQError
          # crystal-pg reports the server's ErrorResponse fields by
          # protocol-symbol name; the severity libpq prints ahead of
          # the message is :severity (a connect-time rejection is
          # always FATAL).
          severity = cause.field_message(:severity) || "FATAL"
          "#{target_prefix(target)} failed: #{severity}:  #{cause.message}\n"
        when Socket::Addrinfo::Error
          libpq_dns_error(target[:host], target[:port])
        when IO::Error
          io_error_detail(cause, target, timeout_set)
        else
          io_error_detail(nil, target, timeout_set)
        end
      end

      # The socket-layer failure text for everything that is not a
      # server-side ErrorResponse or a failed lookup.
      #
      # For TCP, Crystal's Socket::ConnectError cannot be trusted to
      # carry the real errno (its message/os_error have been observed
      # misreporting ECONNREFUSED as "Resource temporarily unavailable"
      # and collapsing ECONNRESET/ENETUNREACH/ETIMEDOUT into the same
      # class), so the errno is re-derived at error-report time with a
      # direct non-blocking probe connect to the same host:port:
      #
      # - probe connects (errno 0): the server accepts connections, so
      #   the original failure happened after connect - the server
      #   dropped the connection during startup, which is libpq's
      #   "server closed the connection unexpectedly" wording (no
      #   "Is the server running..." hint line, live-verified).
      # - probe fails with an errno: that errno's own strerror text,
      #   plus libpq's "Is the server running..." hint line (matches
      #   real for ECONNREFUSED/ENETUNREACH/ETIMEDOUT and any other
      #   errno).
      # - probe itself times out (its connect still EINPROGRESS when
      #   the poll window closes, i.e. the target blackholes SYNs):
      #   worded as ETIMEDOUT ("Connection timed out"), which is what
      #   a natural (unbounded) connect to such a target ends up
      #   reporting too - live-verified against real with a blackhole
      #   address (192.0.2.1, ~2min system timeout): "Connection timed
      #   out". Real words a *libpq connect_timeout* expiry differently
      #   ("timeout expired", no hint, when a connect_timeout is set);
      #   when *timeout_set* says one was set, that is the wording used
      #   here too: real's own poll deadline is what ends a connect to
      #   a still-blackholed target, before the kernel can ever report
      #   anything. This also covers the mid-flight teardown bug this
      #   module works around (see #connect_within_deadline): a connect
      #   the fiber lost at ~1s whose probe is STILL EINPROGRESS was
      #   never a real refusal, and with a deadline set real never
      #   reports an errno for it.
      # - probe impossible (no fd, resolution failing now): falls back
      #   to the wording the old code printed for every TCP failure.
      #
      # For a Unix socket the connect-phase errno is decided by the
      # socket directory's existence, as before (ENOENT for a missing
      # directory, ECONNREFUSED for a present one with no listener).
      private def self.io_error_detail(cause : IO::Error?, target : {host: String?, port: String, unix_socket: String?}, timeout_set : Bool = false) : String
        if unix_socket = target[:unix_socket]
          "#{target_prefix(target)} failed: #{unix_connect_strerror(unix_socket)}\n\t#{hint(target)}\n"
        else
          probe_wording(probe_tcp_connect_errno(target[:host] || "", target[:port]), target, timeout_set)
        end
      end

      # The wording for a probe result (see #io_error_detail for the
      # live-verified cases). Split from the probing itself so the
      # deadline-vs-errno decision stays unit-testable without a real
      # blackhole route.
      def self.probe_wording(probe : {errno: Int32, pending: Bool}?, target : {host: String?, port: String, unix_socket: String?}, timeout_set : Bool) : String
        if probe.nil?
          "#{target_prefix(target)} failed: Connection refused\n\t#{hint(target)}\n"
        elsif probe[:errno].zero?
          "#{target_prefix(target)} failed: #{SERVER_CLOSED_TEXT}"
        elsif probe[:pending] && timeout_set
          "#{target_prefix(target)} failed: timeout expired\n"
        else
          "#{target_prefix(target)} failed: #{Errno.new(probe[:errno]).message}\n\t#{hint(target)}\n"
        end
      end

      # errno of a fresh non-blocking connect to host:port, or nil when
      # the probe cannot even be attempted (socket()/fcntl() failure,
      # or the host no longer resolving). 0 means connected. `pending`
      # is true only when the probe's connect was still EINPROGRESS
      # when its poll window closed - i.e. the target blackholes SYNs
      # and nothing was ever refused - in which case the errno is the
      # ETIMEDOUT stand-in, not a kernel-reported one.
      private PROBE_TIMEOUT_MS = 3000

      # poll(2)'s POLLOUT event bit (Linux poll.h: 0x004) - named locally
      # so the probe never depends on which compilation unit happened to
      # declare LibC's poll(2) bindings (plugins/expect.cr does in the
      # fat plugin build).
      private PROBE_POLLOUT = 0x004

      private def self.probe_tcp_connect_errno(host : String, port : String) : {errno: Int32, pending: Bool}?
        address : Socket::IPAddress? = begin
          # A literal IP (the overwhelmingly common login_host:) is
          # probed verbatim - resolving it could in principle return a
          # different address than the one the failed connect used.
          Socket::IPAddress.new(host, port.to_i)
        rescue
          # Not a literal: resolve. A lookup failing NOW means the
          # probe cannot be attempted (nil).
          begin
            Socket::Addrinfo.tcp(host, port.to_i).first?.try(&.ip_address)
          rescue
            nil
          end
        end
        return nil unless address
        fd = LibC.socket(address.family.value, LibC::SOCK_STREAM, LibC::IPPROTO_TCP)
        return nil if fd < 0
        result : {errno: Int32, pending: Bool}? = nil
        begin
          flags = LibC.fcntl(fd, LibC::F_GETFL, 0)
          if flags >= 0
            LibC.fcntl(fd, LibC::F_SETFL, flags | LibC::O_NONBLOCK)
          end
          rc = LibC.connect(fd, address.to_unsafe, address.size)
          if rc.zero?
            result = {errno: 0, pending: false}
          elsif (e = Errno.value) == Errno::EINPROGRESS
            {% if flag?(:linux) %}
              pfd = LibC::Pollfd.new(fd: fd, events: PROBE_POLLOUT.to_i16, revents: 0i16)
              rc = LibC.poll(pointerof(pfd), 1, PROBE_TIMEOUT_MS)
              if rc <= 0
                result = {errno: Errno::ETIMEDOUT.value, pending: true}
              else
                so_err = 0
                len = LibC::SocklenT.new(sizeof(Int32))
                if LibC.getsockopt(fd, LibC::SOL_SOCKET, LibC::SO_ERROR, pointerof(so_err), pointerof(len)).zero?
                  result = {errno: so_err, pending: false}
                else
                  result = {errno: Errno.value.value, pending: false}
                end
              end
            {% else %}
              result = {errno: Errno::ETIMEDOUT.value, pending: true}
            {% end %}
          else
            result = {errno: e.value, pending: false}
          end
        ensure
          LibC.close(fd)
        end
        result
      end

      # The Unix-socket variant of the old connect() failure text: a
      # missing socket directory is ENOENT; a present one with no
      # listening socket is ECONNREFUSED.
      private def self.unix_connect_strerror(unix_socket : String) : String
        if Dir.exists?(unix_socket)
          "Connection refused"
        else
          "No such file or directory"
        end
      end

      # libpq's own DNS-failure wording. Crystal's Socket::Addrinfo::Error
      # carries no gai code, so the exact getaddrinfo failure is
      # re-derived by re-running getaddrinfo on the same node/service the
      # plugin dialed (the same AF_UNSPEC/STREAM hints crystal-pg
      # resolves with) and printing that code's own gai_strerror text.
      # Should the re-check find the host resolvable (the failure was
      # transient and recovered before this re-check ran), EAI_NONAME's
      # text stands in as the overwhelmingly more common wording for a
      # failed lookup.
      private def self.libpq_dns_error(host : String?, port : String) : String
        host ||= ""
        hints = LibC::Addrinfo.new
        hints.ai_family = LibC::AF_UNSPEC
        hints.ai_socktype = LibC::SOCK_STREAM
        code = LibC.getaddrinfo(host, port, pointerof(hints), out addrs)
        LibC.freeaddrinfo(addrs) if addrs && code == 0
        gai_error_text(host, code == 0 ? LibC::EAI_NONAME : code)
      end

      # libpq's "could not translate host name" wording for an EAI_*
      # code: gai_strerror's text for the code itself, except EAI_SYSTEM
      # which libpq's connectDBStart words with strerror(errno) instead
      # (glibc's gai_strerror would say "System error").
      def self.gai_error_text(host : String, code : Int32) : String
        detail =
          if code == LibC::EAI_SYSTEM
            Errno.value.message
          else
            gai_strerror_text(code)
          end
        "could not translate host name \"#{host}\" to address: #{detail}\n"
      end

      # gai_strerror(3)'s text for an EAI_* code - glibc's on this
      # platform, which is what libpq prints verbatim.
      def self.gai_strerror_text(code : Int32) : String
        String.new(LibC.gai_strerror(code))
      end

      # crystal-pg wraps every connect-stage failure in a
      # PQ::ConnectionError whose cause is the socket-layer exception
      # that actually failed (or, for a server-side rejection, raises
      # PQ::PQError directly), so the diagnostic wants the innermost
      # exception - but only through PQ::ConnectionError, never
      # through a PQError's own chain.
      private def self.unwrap(ex : Exception?) : Exception?
        return nil unless ex
        return ex.cause if ex.is_a?(PQ::ConnectionError)
        ex
      end

      private def self.target_prefix(target : {host: String?, port: String, unix_socket: String?}) : String
        if unix_socket = target[:unix_socket]
          "connection to server on socket \"#{unix_socket}/.s.PGSQL.#{target[:port]}\""
        else
          "connection to server at \"#{target[:host]}\", port #{target[:port]}"
        end
      end

      private def self.hint(target : {host: String?, port: String, unix_socket: String?}) : String
        if target[:unix_socket]
          "Is the server running locally and accepting connections on that socket?"
        else
          "Is the server running on that host and accepting TCP/IP connections?"
        end
      end

      # Resolves the login_host:/login_port:/login_user:/
      # login_unix_socket: params from a plugin's raw `@params`,
      # falling back to each one's real-Ansible deprecated alias
      # (`host:`/`port:`/`login:`/`unix_socket:` respectively -
      # `login_password:` has none) when the canonical `login_*` form
      # isn't set. Shared by postgresql_db.cr/postgresql_user.cr/
      # postgresql_privs.cr so the alias list only lives in one place.
      #
      # Real bug found benchmarking robertdebock.postgres (round 43):
      # its own "Create postgres users" task writes `port: "{{
      # postgres_port }}"` (the alias, for a non-default port like
      # 6543) - each plugin only ever read `login_port:`, so the
      # connection silently fell back to port 5432's Unix socket
      # instead, which doesn't exist on this host at all
      # (`DB::ConnectionRefused` / `PQ::ConnectionError: Cannot
      # establish connection`, confirmed via direct debug instrumentation
      # against a live host - the same URI, built by hand with the
      # correct port included, connected via `psql` immediately).
      def self.resolve_login_params(params : Hash(String, String)) : {host: String?, port: String?, user: String?, password: String?, unix_socket: String?}
        {
          host:        params["login_host"]? || params["host"]?,
          port:        params["login_port"]? || params["port"]?,
          user:        params["login_user"]? || params["login"]?,
          password:    params["login_password"]?,
          unix_socket: params["login_unix_socket"]? || params["unix_socket"]?,
        }
      end
    end
  end
end

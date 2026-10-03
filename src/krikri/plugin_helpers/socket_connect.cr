require "socket"
require "uri"

module Krikri
  module PluginHelpers
    # SocketConnect - TCP connect helpers that report the error the kernel
    # actually recorded, plus the Python-shaped text real Ansible's messages
    # are built from.
    #
    # Why this exists: Crystal 1.21.1's polling event loop
    # (crystal/event_loop/polling.cr, `connect`) learns the outcome of a
    # non-blocking connect from `getsockopt(SO_ERROR)` but then raises it via
    # `Socket::ConnectError.from_errno("connect")`, which re-reads the *live*
    # libc `errno` instead of the value it just fetched. Anything the event
    # loop did in between (epoll_wait, a non-blocking read) leaves a different
    # errno behind, so a refused connect surfaces as
    # `[Errno 11] Resource temporarily unavailable` (EAGAIN) or
    # `[Errno 115] Operation now in progress` (EINPROGRESS) rather than
    # ECONNREFUSED. 1.21.0 got this right by re-issuing `connect(2)` after the
    # wait, which makes the kernel report the real error on the second call.
    # (Reading SO_ERROR afterwards does not help either: on Linux getsockopt
    # CLEARS it, so by the time the exception reaches us it is already gone.)
    #
    # So we never let Crystal's `#connect` make the syscall for us: we issue
    # `connect(2)` on a non-blocking socket, wait for writability ourselves and
    # read SO_ERROR before anything else can consume it. That is what makes
    # `open` below report ECONNREFUSED, and `probe_errno` - which repeats the
    # connect against a target whose socket we no longer own, for the
    # HTTP::Client-based plugins - report it too.
    module SocketConnect
      # Upper bound on the re-probe in `urlopen_error_text`: a refused or
      # unreachable target answers instantly, so this only bounds the targets
      # that hang - which are the ones the original failure already tells us
      # about (Crystal raises IO::TimeoutError for those, no probe at all).
      PROBE_TIMEOUT = 5.seconds

      # Errnos that only ever mean "this connect is still in flight", never
      # what actually went wrong with it.
      IN_FLIGHT_ERRNOS = {Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::EINPROGRESS, Errno::EALREADY}

      # Connects to `host:port` and returns the connected socket, raising
      # `Socket::ConnectError` carrying the REAL errno on failure (or
      # `IO::TimeoutError` when the connect outlives `connect_timeout`, the
      # same shape `TCPSocket.new` raises). Every resolved address is tried,
      # like `TCPSocket.new` and Python's `socket.create_connection`.
      def self.open(host : String, port, connect_timeout : Time::Span? = nil) : Socket
        socket = Socket::Addrinfo.resolve(host, port, Socket::Family::UNSPEC, Socket::Type::STREAM, Socket::Protocol::TCP) do |addrinfo|
          candidate = Socket.tcp(addrinfo.family)
          # Crystal's own #connect would raise the mis-mapped errno and consume
          # SO_ERROR on the way out, so the syscall is ours.
          errno = attempt(candidate, addrinfo, connect_timeout)
          if errno == Errno::NONE
            candidate
          else
            candidate.close
            # A non-nil Exception tells Addrinfo.resolve to keep trying the
            # remaining addresses and to re-raise this one (with its os_error
            # intact) once they run out.
            Socket::ConnectError.from_os_error(nil, errno)
          end
        end.as(Socket?)

        # getaddrinfo came back with no address to try at all
        unless socket
          raise Socket::ConnectError.from_os_error("Error connecting to '#{host}:#{port}'", Errno::EHOSTUNREACH)
        end

        socket
      end

      # Re-runs the connect to `host:port` purely to learn what the kernel
      # said, then closes the socket: nil when the connect succeeded (the port
      # came back up between the original attempt and this one) or when it
      # timed out. Used by the HTTP::Client-based plugins, whose socket is
      # owned by the client and therefore already gone - with its SO_ERROR read
      # and discarded - by the time the exception reaches us.
      def self.probe_errno(host : String, port, timeout : Time::Span = PROBE_TIMEOUT) : Errno?
        begin
          open(host, port, timeout).close
          nil
        rescue IO::TimeoutError
          nil
        rescue ex : Socket::ConnectError
          ex.os_error.as?(Errno)
        rescue
          nil
        end
      end

      # Python's `str(OSError)`: "[Errno 111] Connection refused". Built from
      # the same libc strerror Python's os.strerror uses, so the text matches
      # real Ansible's on the same host.
      def self.python_error_text(errno : Errno) : String
        "[Errno #{errno.value}] #{errno.message}"
      end

      # Python's exception class for an OSError carrying `errno` - the part
      # real's messages put in parentheses (dnspython's OSError shape for
      # nsupdate, urlopen's URLError text for uri/get_url).
      def self.python_exception_name(errno : Errno) : String
        case errno
        when .econnrefused? then "ConnectionRefusedError"
        when .etimedout?    then "TimeoutError"
        when .eacces?       then "PermissionError"
        when .ehostunreach? then "HostUnreachableError"
        when .enetunreach?  then "NetworkUnreachableError"
        else                     "OSError"
        end
      end

      # urllib's URLError str() - "<urlopen error [Errno 111] Connection
      # refused>" - for a connect that failed, or nil when `ex` is not a
      # connect failure (or its real errno could not be recovered), so the
      # caller can keep its own message. A name-resolution failure is NOT
      # one: getaddrinfo carries its own errno, which the caller already
      # reports correctly.
      def self.urlopen_error_text(host : String, port, ex : Exception) : String?
        return nil unless ex.is_a?(Socket::ConnectError)

        errno = probe_errno(host, port)
        unless errno
          # No second opinion: fall back to the errno the exception carries,
          # but only when it is not one of the "still in flight" errnos that
          # Crystal's connect bug can report for any failed connect.
          reported = ex.as?(IO::Error).try(&.os_error).as?(Errno)
          return nil if reported.nil? || IN_FLIGHT_ERRNOS.includes?(reported)
          errno = reported
        end

        "<urlopen error #{python_error_text(errno)}>"
      end

      # Same, for the URL an HTTP::Client was pointed at: the port default
      # mirrors the client's own (explicit port, else 443 for https and 80
      # otherwise), so the re-probe hits the same endpoint the request did.
      def self.urlopen_error_text(url : URI, ex : Exception) : String?
        host = url.host
        return nil unless host
        urlopen_error_text(host, url.port || (url.scheme == "https" ? 443 : 80), ex)
      end

      # Runs connect(2) on `socket` (already non-blocking, as the event loop
      # configures it) and resolves the connection attempt: Errno::NONE when
      # connected, the real errno when the kernel refused it. Raises
      # IO::TimeoutError when the attempt outlives `timeout`.
      private def self.attempt(socket : Socket, addrinfo : Socket::Addrinfo, timeout : Time::Span?) : Errno
        return Errno::NONE if LibC.connect(socket.fd, addrinfo.to_unsafe, addrinfo.size) == 0

        errno = Errno.value
        return errno unless IN_FLIGHT_ERRNOS.includes?(errno)

        # The socket is writable once the attempt is over - either connected
        # or failed - and SO_ERROR then says which.
        socket.write_timeout = timeout
        begin
          Crystal::EventLoop.current.wait_writable(socket)
        rescue IO::TimeoutError
          raise IO::TimeoutError.new("Connect timed out")
        end

        # no pending SO_ERROR means the attempt actually succeeded
        pending_errno(socket) || Errno::NONE
      end

      # getsockopt's SO_ERROR option number. Crystal 1.21.1's LibC bindings
      # define LibC::SO_ERROR, but the 1.21.0 toolchain the release workflow
      # pins (musl/Alpine images and the macOS runners) does not - referencing
      # it there is a compile error ("undefined constant LibC::SO_ERROR") that
      # a glibc 1.21.1 dev build never shows. The numbers are the kernel ABI's:
      # 4 on Linux (every architecture), 0x1007 on macOS and the BSDs.
      {% if LibC.has_constant?("SO_ERROR") %}
        SO_ERROR_OPTION = LibC::SO_ERROR
      {% elsif flag?(:linux) %}
        SO_ERROR_OPTION = 4
      {% else %}
        SO_ERROR_OPTION = 0x1007
      {% end %}

      # The connect error the kernel recorded for `socket`, read before
      # anything else can (a successful getsockopt CLEARS it on Linux).
      private def self.pending_errno(socket : Socket) : Errno?
        value = 0
        size = LibC::SocklenT.new(sizeof(Int32))
        return nil if LibC.getsockopt(socket.fd, LibC::SOL_SOCKET, SO_ERROR_OPTION, pointerof(value), pointerof(size)) == -1

        errno = Errno.new(value)
        errno == Errno::NONE ? nil : errno
      end
    end
  end
end

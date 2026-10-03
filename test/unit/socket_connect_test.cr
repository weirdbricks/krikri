require "../minitest_helper"
require "../../src/krikri/plugin_helpers/socket_connect"

private alias SocketConnect = Krikri::PluginHelpers::SocketConnect

# Crystal 1.21.1's polling event loop reports the LIVE libc errno for a
# connect that failed asynchronously instead of the SO_ERROR it just read
# (crystal/event_loop/polling.cr, `connect`: `Socket::ConnectError.
# from_errno("connect")` after `system_error`), so a refused connect came
# back as EAGAIN/EINPROGRESS - "Resource temporarily unavailable" instead
# of "Connection refused" - in every module that opens a socket. These pin
# the errno the kernel actually recorded, which is what real Python's
# `[Errno 111] Connection refused` text is built from.
describe SocketConnect do
  # A port nothing listens on: connecting gets the kernel's ECONNREFUSED.
  private def refused_connect_error(host : String = "127.0.0.1", port : Int32 = 1) : Socket::ConnectError
    begin
      SocketConnect.open(host, port, 5.seconds)
      raise "expected the connect to fail"
    rescue ex : Socket::ConnectError
      ex
    end
  end

  describe ".open" do
    it "reports ECONNREFUSED for a refused connect, not the in-flight errno" do
      error = refused_connect_error

      error.os_error.as?(Errno).must_equal(Errno::ECONNREFUSED)
      error.message.must_equal("Error connecting to '127.0.0.1:1': Connection refused")
    end

    it "connects to a live listener" do
      server = TCPServer.new("127.0.0.1", 0)
      port = (server.local_address || raise "unexpected nil").port
      socket = SocketConnect.open("127.0.0.1", port, 5.seconds)
      socket.print("hi")
      socket.flush
      socket.close
      server.close
    end

    it "raises the timeout shape Crystal's own connect raises" do
      # TEST-NET-1 (192.0.2.0/24) is reserved for documentation, so nothing
      # answers and the connect is still in flight when the timeout expires.
      error = begin
        SocketConnect.open("192.0.2.1", 81, 100.milliseconds)
        nil
      rescue ex : IO::TimeoutError
        ex
      end

      (error || raise "unexpected nil").message.must_equal("Connect timed out")
    end
  end

  describe ".probe_errno" do
    it "learns the refused errno for a target whose socket is already gone" do
      SocketConnect.probe_errno("127.0.0.1", 1).must_equal(Errno::ECONNREFUSED)
    end

    it "is nil when the target answers" do
      server = TCPServer.new("127.0.0.1", 0)
      port = (server.local_address || raise "unexpected nil").port
      SocketConnect.probe_errno("127.0.0.1", port).must_be_nil
      server.close
    end
  end

  describe ".python_error_text" do
    it "renders Python's str(OSError) text" do
      SocketConnect.python_error_text(Errno::ECONNREFUSED).must_equal("[Errno 111] Connection refused")
    end

    it "renders the timeout errno's own text" do
      SocketConnect.python_error_text(Errno::ETIMEDOUT).must_equal("[Errno 110] Connection timed out")
    end
  end

  describe ".python_exception_name" do
    it "names the Python exception class per errno" do
      SocketConnect.python_exception_name(Errno::ECONNREFUSED).must_equal("ConnectionRefusedError")
      SocketConnect.python_exception_name(Errno::ETIMEDOUT).must_equal("TimeoutError")
      SocketConnect.python_exception_name(Errno::EACCES).must_equal("PermissionError")
      SocketConnect.python_exception_name(Errno::ENETUNREACH).must_equal("NetworkUnreachableError")
      SocketConnect.python_exception_name(Errno::EHOSTUNREACH).must_equal("HostUnreachableError")
      SocketConnect.python_exception_name(Errno::ECONNRESET).must_equal("OSError")
    end
  end

  describe ".urlopen_error_text" do
    it "renders urllib's URLError text for a refused connect" do
      SocketConnect.urlopen_error_text("127.0.0.1", 1, refused_connect_error).must_equal(
        "<urlopen error [Errno 111] Connection refused>")
    end

    it "recovers the errno even when the exception carries Crystal's wrong one" do
      # exactly what HTTP::Client hands the plugins: a ConnectError whose
      # os_error is whatever the event loop left in errno.
      wrong = Socket::ConnectError.from_os_error("Error connecting to '127.0.0.1:1'", Errno::EAGAIN)

      SocketConnect.urlopen_error_text("127.0.0.1", 1, wrong).must_equal(
        "<urlopen error [Errno 111] Connection refused>")
    end

    it "is nil for an error that is not a connect failure" do
      SocketConnect.urlopen_error_text("127.0.0.1", 1, IO::EOFError.new("")).must_be_nil
    end

    it "takes the port default from the URL the way HTTP::Client does" do
      uri = URI.parse("http://127.0.0.1/")

      SocketConnect.urlopen_error_text(uri, refused_connect_error).must_equal(
        "<urlopen error [Errno 111] Connection refused>")
    end
  end
end

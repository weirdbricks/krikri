require "../minitest_helper"
require "socket"
require "pg"
require "../../src/krikri/plugin_helpers/postgresql_connection"

describe Krikri::PluginHelpers::PostgresqlConnection do
  describe ".build_uri" do
    it "defaults to a Unix socket connection, not TCP localhost, when no host: is given" do
      # Real libpq (and psycopg2, which every postgresql_db/
      # postgresql_user real-Ansible run underneath actually uses)
      # defaults to a Unix socket connection when no host: is given at
      # all - NOT TCP to "localhost". Real bug found benchmarking
      # robertdebock.postgres (round 43): its own "Create postgres
      # database"/"Create postgres users" tasks never set login_host:,
      # relying on that Unix-socket-by-default behavior (peer auth,
      # matching the task's own become_user: postgres) - forcing TCP
      # instead hit real pg_hba.conf's `ident` gate for TCP connections
      # (no ident daemon running) and failed outright, while
      # Ansible connected fine via the socket's `peer` auth.
      Krikri::PluginHelpers::PostgresqlConnection.build_uri.must_equal(
        "postgres:/postgres?host=%2Fvar%2Frun%2Fpostgresql"
      )
    end

    it "passes a non-default port through as a query param on the default Unix socket path" do
      # crystal-pg's socket-directory lookup builds the actual socket
      # filename as `.s.PGSQL.<port>` - a non-default port (e.g.
      # robertdebock.postgres's own `postgres_port: 6543`) must reach it
      # via the "port" query param, not just discarded.
      Krikri::PluginHelpers::PostgresqlConnection.build_uri(port: "6543").must_equal(
        "postgres:/postgres?host=%2Fvar%2Frun%2Fpostgresql&port=6543"
      )
    end

    it "builds a TCP URI with host/port/user/password/dbname" do
      uri = Krikri::PluginHelpers::PostgresqlConnection.build_uri(
        host: "db.example.com", port: "5433", user: "postgres", password: "secret", dbname: "mydb"
      )
      uri.must_equal("postgres://postgres:secret@db.example.com:5433/mydb")
    end

    it "includes sslmode as a query param when given, still against the default Unix socket" do
      uri = Krikri::PluginHelpers::PostgresqlConnection.build_uri(sslmode: "disable")
      uri.must_equal("postgres:/postgres?host=%2Fvar%2Frun%2Fpostgresql&sslmode=disable")
    end

    it "builds a unix socket URI via the host query param, ignoring host/port" do
      uri = Krikri::PluginHelpers::PostgresqlConnection.build_uri(
        host: "ignored", port: "9999", user: "postgres", unix_socket: "/var/run/postgresql"
      )
      uri.must_equal("postgres://postgres@/postgres?host=%2Fvar%2Frun%2Fpostgresql&port=9999")
    end
  end

  describe ".resolve_login_params" do
    it "falls back to each real-Ansible deprecated alias when the canonical login_* form isn't set" do
      # Real bug found benchmarking robertdebock.postgres (round 43):
      # its own "Create postgres users" task writes `port: "{{
      # postgres_port }}"` (login_port:'s deprecated `port:` alias, for
      # a non-default port like 6543) - postgresql_db.cr/
      # postgresql_user.cr/postgresql_privs.cr all only ever read
      # login_port: directly, so the connection silently fell back to
      # port 5432's Unix socket, which doesn't exist on the target host
      # at all.
      resolved = Krikri::PluginHelpers::PostgresqlConnection.resolve_login_params({
        "host"        => "aliased-host",
        "port"        => "6543",
        "login"       => "aliased-user",
        "unix_socket" => "/aliased/socket",
      })

      resolved[:host].must_equal("aliased-host")
      resolved[:port].must_equal("6543")
      resolved[:user].must_equal("aliased-user")
      resolved[:unix_socket].must_equal("/aliased/socket")
    end

    it "prefers the canonical login_* form over the alias when both are set" do
      resolved = Krikri::PluginHelpers::PostgresqlConnection.resolve_login_params({
        "login_host"        => "canonical-host",
        "host"              => "aliased-host",
        "login_port"        => "5432",
        "port"              => "6543",
        "login_user"        => "canonical-user",
        "login"             => "aliased-user",
        "login_unix_socket" => "/canonical/socket",
        "unix_socket"       => "/aliased/socket",
      })

      resolved[:host].must_equal("canonical-host")
      resolved[:port].must_equal("5432")
      resolved[:user].must_equal("canonical-user")
      resolved[:unix_socket].must_equal("/canonical/socket")
    end
  end

  # libpq words a failed getaddrinfo with the code's own gai_strerror  # text (its connectDBStart branch: "could not translate host name
  # \"%s\" to address: %s", %s = strerror(errno) for EAI_SYSTEM,
  # gai_strerror(code) otherwise). Crystal's Socket::Addrinfo::Error
  # carries no gai code, so the plugin re-derives the code with a
  # direct LibC.getaddrinfo call and prints this wording - every
  # expected text below is glibc's gai_strerror on this machine, and
  # the EAI_NONAME/EAI_AGAIN pair was additionally live-verified
  # against psql 16.14 and real ansible-core 2.19.11 +
  # community.postgresql 4.2.0 (no network needed here: these tests
  # exercise the code->message mapping directly).

  describe ".gai_strerror_text" do
    it "maps every glibc EAI_* code to its gai_strerror text" do
      map = {
        LibC::EAI_NONAME   => "Name or service not known",
        LibC::EAI_AGAIN    => "Temporary failure in name resolution",
        LibC::EAI_FAIL     => "Non-recoverable failure in name resolution",
        LibC::EAI_NODATA   => "No address associated with hostname",
        LibC::EAI_FAMILY   => "ai_family not supported",
        LibC::EAI_SOCKTYPE => "ai_socktype not supported",
        LibC::EAI_SERVICE  => "Servname not supported for ai_socktype",
        LibC::EAI_MEMORY   => "Memory allocation failure",
        LibC::EAI_OVERFLOW => "Result too large for supplied buffer",
      }
      map.each do |code, text|
        Krikri::PluginHelpers::PostgresqlConnection.gai_strerror_text(code).must_equal(text)
      end
    end
  end

  describe ".gai_error_text" do
    it "wraps a gai code in libpq's could-not-translate wording" do
      Krikri::PluginHelpers::PostgresqlConnection.gai_error_text("nosuchhost.invalid", LibC::EAI_NONAME).must_equal(
        "could not translate host name \"nosuchhost.invalid\" to address: Name or service not known\n"
      )
      Krikri::PluginHelpers::PostgresqlConnection.gai_error_text("example.org", LibC::EAI_AGAIN).must_equal(
        "could not translate host name \"example.org\" to address: Temporary failure in name resolution\n"
      )
    end

    it "words EAI_SYSTEM with strerror(errno), not gai_strerror" do
      # glibc's gai_strerror would say "System error" here; libpq
      # special-cases EAI_SYSTEM to strerror(errno) instead (source, not
      # live-verified - a deterministic EAI_SYSTEM needs a broken
      # resolver socket, not worth a contrived harness).
      text = Krikri::PluginHelpers::PostgresqlConnection.gai_error_text("host", LibC::EAI_SYSTEM)
      text.must_equal("could not translate host name \"host\" to address: #{Errno.value.message}\n")
      text.wont_equal("could not translate host name \"host\" to address: System error\n")
    end
  end

  # The socket-layer connect-error wording. Crystal's
  # Socket::ConnectError cannot be trusted to carry the real errno (its
  # message has been observed misreporting a refused connect as
  # "Resource temporarily unavailable", and it collapses every connect
  # errno into one class), so the errno is re-derived with a direct
  # non-blocking probe connect at error-report time - hence the real
  # listening/closed sockets below, not just fake exceptions.
  describe ".libpq_connect_error socket-layer detail" do
    def self.refused_chain(message : String)
      DB::ConnectionRefused.new(message, cause: PQ::ConnectionError.new("Cannot establish connection", cause: Socket::ConnectError.new(message)))
    end

    it "words an accept-then-close TCP failure like real libpq (no hint line)" do
      # Live-verified against real ansible-core 2.19.11 +
      # community.postgresql 4.2.0 behind a python accept-then-close
      # listener: "unable to connect to database: connection to server
      # at \"127.0.0.1\", port N failed: server closed the connection
      # unexpectedly\n\tThis probably means the server terminated
      # abnormally\n\tbefore or while processing the request.\n"
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      begin
        # Never accepted on purpose: the probe connect only needs the
        # listen backlog to complete, mirroring what the error-report
        # path sees after the real failure.
        ex = DB::ConnectionRefused.new("Cannot establish connection", cause: PQ::ConnectionError.new("Cannot establish connection", cause: IO::EOFError.new("EOF")))
        Krikri::PluginHelpers::PostgresqlConnection.libpq_connect_error(
          ex, {host: "127.0.0.1", port: port.to_s, unix_socket: nil}
        ).must_equal(
          "connection to server at \"127.0.0.1\", port #{port} failed: " \
          "server closed the connection unexpectedly\n" \
          "\tThis probably means the server terminated abnormally\n" \
          "\tbefore or while processing the request.\n"
        )
      ensure
        server.close
      end
    end

    it "words an accept-then-RST TCP failure the same as accept-then-close" do
      # The old code printed the exception's own message here (the
      # flapping "read (#<TCPSocket:0x...>): Connection reset by peer"
      # text); real libpq reports the deterministic "server closed"
      # wording for an RST on the accepted socket too.
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      begin
        cause = IO::Error.new("read (#<TCPSocket:0xdeadbeef>): Connection reset by peer")
        ex = DB::ConnectionRefused.new("Cannot establish connection", cause: PQ::ConnectionError.new("Cannot establish connection", cause: cause))
        text = Krikri::PluginHelpers::PostgresqlConnection.libpq_connect_error(
          ex, {host: "127.0.0.1", port: port.to_s, unix_socket: nil}
        )
        text.must_equal(
          "connection to server at \"127.0.0.1\", port #{port} failed: " \
          "server closed the connection unexpectedly\n" \
          "\tThis probably means the server terminated abnormally\n" \
          "\tbefore or while processing the request.\n"
        )
        text.includes?("TCPSocket").must_equal(false)
      ensure
        server.close
      end
    end

    it "keeps the Connection refused wording plus hint for a closed port" do
      # Port 1 (tcpmux) has nothing listening on any test host.
      ex = self.class.refused_chain("Cannot establish connection")
      Krikri::PluginHelpers::PostgresqlConnection.libpq_connect_error(
        ex, {host: "127.0.0.1", port: "1", unix_socket: nil}
      ).must_equal(
        "connection to server at \"127.0.0.1\", port 1 failed: Connection refused\n" \
        "\tIs the server running on that host and accepting TCP/IP connections?\n"
      )
    end

    it "falls back to the refused wording when the probe cannot be attempted" do
      # An unresolvable host can't be probed; the resolution failure is
      # normally caught earlier (Socket::Addrinfo::Error branch), so a
      # host that stopped resolving between connect and report lands
      # here. The probe's nil must not crash or invent an errno.
      cause = IO::Error.new("read (#<TCPSocket:0xdeadbeef>): Connection reset by peer")
      ex = DB::ConnectionRefused.new("Cannot establish connection", cause: PQ::ConnectionError.new("Cannot establish connection", cause: cause))
      Krikri::PluginHelpers::PostgresqlConnection.libpq_connect_error(
        ex, {host: "nosuchhost.invalid", port: "5432", unix_socket: nil}
      ).must_equal(
        "connection to server at \"nosuchhost.invalid\", port 5432 failed: Connection refused\n" \
        "\tIs the server running on that host and accepting TCP/IP connections?\n"
      )
    end

    it "keeps the unix-socket ENOENT vs refused distinction" do
      ex = self.class.refused_chain("Cannot establish connection")
      missing = PluginSpecHelper.tmp_path("nosuch-sockdir")
      Krikri::PluginHelpers::PostgresqlConnection.libpq_connect_error(
        ex, {host: nil, port: "5432", unix_socket: missing}
      ).must_equal(
        "connection to server on socket \"#{missing}/.s.PGSQL.5432\" failed: No such file or directory\n" \
        "\tIs the server running locally and accepting connections on that socket?\n"
      )
      present = PluginSpecHelper.tmp_path("empty-sockdir")
      Dir.mkdir_p(present)
      Krikri::PluginHelpers::PostgresqlConnection.libpq_connect_error(
        ex, {host: nil, port: "5432", unix_socket: present}
      ).must_equal(
        "connection to server on socket \"#{present}/.s.PGSQL.5432\" failed: Connection refused\n" \
        "\tIs the server running locally and accepting connections on that socket?\n"
      )
    end
  end

  # The deadline-vs-errno wording decision: a probe connect that is
  # still EINPROGRESS when its poll window closes means the target
  # blackholes SYNs and nothing was ever refused - with a
  # connect_timeout set, real libpq's own poll deadline is what ends
  # such an attempt ("timeout expired", no hint line); without one,
  # the natural (unbounded) connect wording stands. A probe that
  # resolved a concrete errno keeps that errno's text either way.
  describe ".libpq_connect_error probe wording under a deadline" do
    alias Target = {host: String?, port: String, unix_socket: String?}

    def self.wording(probe, target : Target, timeout_set : Bool) : String
      Krikri::PluginHelpers::PostgresqlConnection.probe_wording(probe, target, timeout_set)
    end

    it "words a still-pending probe as timeout expired when a deadline is set" do
      self.class.wording(
        {errno: Errno::ETIMEDOUT.value, pending: true},
        {host: "192.0.2.1", port: "5432", unix_socket: nil}, true
      ).must_equal(
        "connection to server at \"192.0.2.1\", port 5432 failed: timeout expired\n"
      )
    end

    it "keeps the natural-timeout wording for a still-pending probe without a deadline" do
      self.class.wording(
        {errno: Errno::ETIMEDOUT.value, pending: true},
        {host: "192.0.2.1", port: "5432", unix_socket: nil}, false
      ).must_equal(
        "connection to server at \"192.0.2.1\", port 5432 failed: Connection timed out\n" \
        "\tIs the server running on that host and accepting TCP/IP connections?\n"
      )
    end

    it "keeps a concrete probe errno's text even when a deadline is set" do
      self.class.wording(
        {errno: Errno::ECONNREFUSED.value, pending: false},
        {host: "127.0.0.1", port: "1", unix_socket: nil}, true
      ).must_equal(
        "connection to server at \"127.0.0.1\", port 1 failed: Connection refused\n" \
        "\tIs the server running on that host and accepting TCP/IP connections?\n"
      )
    end

    it "keeps the connected-probe server-closed wording" do
      self.class.wording(
        {errno: 0, pending: false},
        {host: "127.0.0.1", port: "5432", unix_socket: nil}, true
      ).must_equal(
        "connection to server at \"127.0.0.1\", port 5432 failed: " \
        "server closed the connection unexpectedly\n" \
        "\tThis probably means the server terminated abnormally\n" \
        "\tbefore or while processing the request.\n"
      )
    end

    it "falls back to the refused wording when the probe cannot be attempted" do
      self.class.wording(
        nil, {host: "192.0.2.1", port: "5432", unix_socket: nil}, true
      ).must_equal(
        "connection to server at \"192.0.2.1\", port 5432 failed: Connection refused\n" \
        "\tIs the server running on that host and accepting TCP/IP connections?\n"
      )
    end
  end
end

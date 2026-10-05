require "../minitest_helper"
require "socket"
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

  # libpq words a failed getaddrinfo with the code's own gai_strerror
  # text (its connectDBStart branch: "could not translate host name
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
end

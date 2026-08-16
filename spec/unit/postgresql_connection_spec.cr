require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/postgresql_connection"

describe CrystalPlay::PluginHelpers::PostgresqlConnection do
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
      # (no ident daemon running) and failed outright, while real
      # Ansible connected fine via the socket's `peer` auth.
      CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri.should eq(
        "postgres:/postgres?host=%2Fvar%2Frun%2Fpostgresql"
      )
    end

    it "passes a non-default port through as a query param on the default Unix socket path" do
      # crystal-pg's socket-directory lookup builds the actual socket
      # filename as `.s.PGSQL.<port>` - a non-default port (e.g.
      # robertdebock.postgres's own `postgres_port: 6543`) must reach it
      # via the "port" query param, not just discarded.
      CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(port: "6543").should eq(
        "postgres:/postgres?host=%2Fvar%2Frun%2Fpostgresql&port=6543"
      )
    end

    it "builds a TCP URI with host/port/user/password/dbname" do
      uri = CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(
        host: "db.example.com", port: "5433", user: "postgres", password: "secret", dbname: "mydb"
      )
      uri.should eq("postgres://postgres:secret@db.example.com:5433/mydb")
    end

    it "includes sslmode as a query param when given, still against the default Unix socket" do
      uri = CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(sslmode: "disable")
      uri.should eq("postgres:/postgres?host=%2Fvar%2Frun%2Fpostgresql&sslmode=disable")
    end

    it "builds a unix socket URI via the host query param, ignoring host/port" do
      uri = CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(
        host: "ignored", port: "9999", user: "postgres", unix_socket: "/var/run/postgresql"
      )
      uri.should eq("postgres://postgres@/postgres?host=%2Fvar%2Frun%2Fpostgresql&port=9999")
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
      resolved = CrystalPlay::PluginHelpers::PostgresqlConnection.resolve_login_params({
        "host"        => "aliased-host",
        "port"        => "6543",
        "login"       => "aliased-user",
        "unix_socket" => "/aliased/socket",
      })

      resolved[:host].should eq("aliased-host")
      resolved[:port].should eq("6543")
      resolved[:user].should eq("aliased-user")
      resolved[:unix_socket].should eq("/aliased/socket")
    end

    it "prefers the canonical login_* form over the alias when both are set" do
      resolved = CrystalPlay::PluginHelpers::PostgresqlConnection.resolve_login_params({
        "login_host"        => "canonical-host",
        "host"              => "aliased-host",
        "login_port"        => "5432",
        "port"              => "6543",
        "login_user"        => "canonical-user",
        "login"             => "aliased-user",
        "login_unix_socket" => "/canonical/socket",
        "unix_socket"       => "/aliased/socket",
      })

      resolved[:host].should eq("canonical-host")
      resolved[:port].should eq("5432")
      resolved[:user].should eq("canonical-user")
      resolved[:unix_socket].should eq("/canonical/socket")
    end
  end
end

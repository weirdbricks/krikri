require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/postgresql_connection"

describe CrystalPlay::PluginHelpers::PostgresqlConnection do
  describe ".build_uri" do
    it "defaults to localhost:5432/postgres with no credentials" do
      CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri.should eq("postgres://localhost:5432/postgres")
    end

    it "builds a TCP URI with host/port/user/password/dbname" do
      uri = CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(
        host: "db.example.com", port: "5433", user: "postgres", password: "secret", dbname: "mydb"
      )
      uri.should eq("postgres://postgres:secret@db.example.com:5433/mydb")
    end

    it "includes sslmode as a query param when given" do
      uri = CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(sslmode: "disable")
      uri.should eq("postgres://localhost:5432/postgres?sslmode=disable")
    end

    it "builds a unix socket URI via the host query param, ignoring host/port" do
      uri = CrystalPlay::PluginHelpers::PostgresqlConnection.build_uri(
        host: "ignored", port: "9999", user: "postgres", unix_socket: "/var/run/postgresql"
      )
      uri.should eq("postgres://postgres@/postgres?host=%2Fvar%2Frun%2Fpostgresql")
    end
  end
end

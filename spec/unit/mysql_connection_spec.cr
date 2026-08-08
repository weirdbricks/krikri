require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/mysql_connection"

describe CrystalPlay::PluginHelpers::MysqlConnection do
  describe ".build_uri" do
    it "defaults to localhost:3306, with the current OS user as the connection username" do
      original_user = ENV["USER"]?
      ENV["USER"] = "specuser"
      CrystalPlay::PluginHelpers::MysqlConnection.build_uri.should eq("mysql://specuser@localhost:3306?ssl-mode=disabled")
    ensure
      if original_user
        ENV["USER"] = original_user
      else
        ENV.delete("USER")
      end
    end

    it "builds a TCP URI with host/port/user/password" do
      uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(host: "db.example.com", port: "3307", user: "root", password: "secret")
      uri.should eq("mysql://root:secret@db.example.com:3307?ssl-mode=disabled")
    end

    it "builds a unix socket URI, ignoring host/port" do
      uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(host: "ignored", port: "9999", user: "root", unix_socket: "/var/run/mysqld/mysqld.sock")
      uri.should eq("mysql://root@/var/run/mysqld/mysqld.sock?ssl-mode=disabled")
    end

    it "falls back to 'root' as the connection username when neither user: nor $USER is available" do
      original_user = ENV["USER"]?
      ENV.delete("USER")
      CrystalPlay::PluginHelpers::MysqlConnection.build_uri(host: "localhost").should eq("mysql://root@localhost:3306?ssl-mode=disabled")
    ensure
      ENV["USER"] = original_user if original_user
    end

    it "always disables TLS, since the mysql shard's own default (preferred) doesn't fall back to plaintext on a failed handshake" do
      CrystalPlay::PluginHelpers::MysqlConnection.build_uri.should contain("ssl-mode=disabled")
    end
  end
end

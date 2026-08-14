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

  describe "option-file (config_file) fallback" do
    # Writes a throwaway my.cnf-format file and returns its path.
    setup = ->(contents : String) {
      path = File.join(Dir.tempdir, "crystal_ansible_spec_mycnf_#{Random.rand(100_000)}")
      File.write(path, contents)
      path
    }

    teardown = ->(path : String) { File.delete?(path) }

    it "reads [client] user/password from the option file when no login params are given" do
      p = setup.call("[client]\nuser=\"root\"\npassword=\"supersecret\"\n")
      begin
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(config_file: p)
        uri.should eq("mysql://root:supersecret@localhost:3306?ssl-mode=disabled")
      ensure
        teardown.call(p)
      end
    end

    it "lets an explicit login_user/login_password override the option file" do
      p = setup.call("[client]\nuser=\"root\"\npassword=\"fromfile\"\n")
      begin
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(user: "bob", password: "explicit", config_file: p)
        uri.should eq("mysql://bob:explicit@localhost:3306?ssl-mode=disabled")
      ensure
        teardown.call(p)
      end
    end

    it "uses only user/password from the option file when login_host is explicit (host not overridden)" do
      p = setup.call("[client]\nuser=\"root\"\npassword=\"pw\"\nsocket=/run/mysqld/mysqld.sock\n")
      begin
        # login_host given => socket from the file is ignored, host honored,
        # but user/password still come from the file.
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(host: "db.example.com", config_file: p)
        uri.should eq("mysql://root:pw@db.example.com:3306?ssl-mode=disabled")
      ensure
        teardown.call(p)
      end
    end

    it "does not honor a [client] socket when login_host is explicit" do
      original_user = ENV["USER"]?
      ENV["USER"] = "specuser"
      p = setup.call("[client]\nsocket=/run/mysqld/mysqld.sock\n")
      begin
        # login_host given => socket ignored, host honored; no user in the
        # file, so the connection username falls back to the OS user.
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(host: "db", config_file: p)
        uri.should eq("mysql://specuser@db:3306?ssl-mode=disabled")
      ensure
        teardown.call(p)
        ENV["USER"] = original_user if original_user
      end
    end

    it "returns no error for a missing option file (treated as absent)" do
      original_user = ENV["USER"]?
      ENV["USER"] = "specuser"
      begin
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(config_file: "/no/such/my.cnf")
        uri.should eq("mysql://specuser@localhost:3306?ssl-mode=disabled")
      ensure
        ENV["USER"] = original_user if original_user
      end
    end

    it "ignores comments and !includedir-style lines, and strips quotes" do
      p = setup.call("#comment\n[client]\n!includedir /etc/mysql/conf.d/\nuser=root\npassword='letmein'\nsocket=/tmp/mysql.sock\n")
      begin
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(config_file: p)
        uri.should eq("mysql://root:letmein@/tmp/mysql.sock?ssl-mode=disabled")
      ensure
        teardown.call(p)
      end
    end

    it "uses defaults when the file has no [client] section" do
      original_user = ENV["USER"]?
      ENV["USER"] = "specuser"
      p = setup.call("[mysqld]\nuser=someuser\npassword=whatever\n")
      begin
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(config_file: p)
        uri.should eq("mysql://specuser@localhost:3306?ssl-mode=disabled")
      ensure
        teardown.call(p)
        ENV["USER"] = original_user if original_user
      end
    end

    it "expands a leading ~ in the config_file using $HOME (matches os.path.expanduser)" do
      original_user = ENV["USER"]?
      original_home = ENV["HOME"]?
      ENV["USER"] = "specuser"
      home = File.join(Dir.tempdir, "crystal_ansible_spec_home_#{Random.rand(100_000)}")
      Dir.mkdir_p(home)
      ENV["HOME"] = home
      File.write(File.join(home, ".my.cnf"), "[client]\nuser=\"root\"\npassword=\"tildehome\"\n")
      begin
        # DEFAULT_OPTION_FILE is "~/.my.cnf" - must resolve via $HOME, not
        # against the CWD (Crystal's File.expand_path does not expand ~).
        uri = CrystalPlay::PluginHelpers::MysqlConnection.build_uri(config_file: "~/.my.cnf")
        uri.should eq("mysql://root:tildehome@localhost:3306?ssl-mode=disabled")
      ensure
        File.delete?(File.join(home, ".my.cnf"))
        Dir.delete?(home)
        ENV["USER"] = original_user if original_user
        ENV["HOME"] = original_home if original_home
      end
    end
  end
end

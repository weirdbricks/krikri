require "../minitest_helper"
require "../../src/krikri/plugin_helpers/mysql_connection"

describe Krikri::PluginHelpers::MysqlConnection do
  serial! # mutates process-global state (ENV / engine settings)

  describe ".build_uri" do
    it "defaults to localhost:3306, with the current OS user as the connection username" do
      PluginSpecHelper::ENV_MUTEX.synchronize do
        original_user = ENV["USER"]?
        ENV["USER"] = "specuser"
        begin
          Krikri::PluginHelpers::MysqlConnection.build_uri.must_equal("mysql://specuser@localhost:3306?ssl-mode=disabled")
        ensure
          if original_user
            ENV["USER"] = original_user
          else
            ENV.delete("USER")
          end
        end
      end
    end

    it "builds a TCP URI with host/port/user/password" do
      uri = Krikri::PluginHelpers::MysqlConnection.build_uri(host: "db.example.com", port: "3307", user: "root", password: "secret")
      uri.must_equal("mysql://root:secret@db.example.com:3307?ssl-mode=disabled")
    end

    it "builds a unix socket URI, ignoring host/port" do
      uri = Krikri::PluginHelpers::MysqlConnection.build_uri(host: "ignored", port: "9999", user: "root", unix_socket: "/var/run/mysqld/mysqld.sock")
      uri.must_equal("mysql://root@/var/run/mysqld/mysqld.sock?ssl-mode=disabled")
    end

    it "falls back to 'root' as the connection username when neither user: nor $USER is available" do
      PluginSpecHelper::ENV_MUTEX.synchronize do
        original_user = ENV["USER"]?
        ENV.delete("USER")
        begin
          Krikri::PluginHelpers::MysqlConnection.build_uri(host: "localhost").must_equal("mysql://root@localhost:3306?ssl-mode=disabled")
        ensure
          ENV["USER"] = original_user if original_user
        end
      end
    end

    it "always disables TLS, since the mysql shard's own default (preferred) doesn't fall back to plaintext on a failed handshake" do
      Krikri::PluginHelpers::MysqlConnection.build_uri.must_include("ssl-mode=disabled")
    end

    it "passes the initial database as a query param, not a URI path" do
      # login_db must reach the shard as `?database=`, not `/dbname` in the
      # path: for unix-socket connections the shard reads the socket path
      # FROM uri.path, so a path component would clobber it. Found via the
      # 2026-09-13 ad-hoc CLI sweep: mysql_query dropped login_db entirely,
      # so every unqualified query failed with "No database selected".
      uri = Krikri::PluginHelpers::MysqlConnection.build_uri(host: "127.0.0.1", user: "compat", password: "pw", db: "compatdb")
      uri.must_equal("mysql://compat:pw@127.0.0.1:3306?ssl-mode=disabled&database=compatdb")
    end

    it "keeps the database param working over a unix socket" do
      uri = Krikri::PluginHelpers::MysqlConnection.build_uri(unix_socket: "/var/run/mysqld/mysqld.sock", user: "root", db: "compatdb")
      uri.must_equal("mysql://root@/var/run/mysqld/mysqld.sock?ssl-mode=disabled&database=compatdb")
    end

    it "omits the database param when no db: is given" do
      Krikri::PluginHelpers::MysqlConnection.build_uri(host: "127.0.0.1", user: "root").wont_include("database=")
    end
  end

  describe "option-file (config_file) fallback" do
    # Writes a throwaway my.cnf-format file and returns its path.
    private def setup(contents : String)
      path = File.join(Dir.tempdir, "crystal_ansible_spec_mycnf_#{Random.rand(100_000)}")
      File.write(path, contents)
      path
    end

    private def teardown(path : String)
      File.delete?(path)
    end

    it "reads [client] user/password from the option file when no login params are given" do
      p = setup("[client]\nuser=\"root\"\npassword=\"supersecret\"\n")
      begin
        uri = Krikri::PluginHelpers::MysqlConnection.build_uri(config_file: p)
        uri.must_equal("mysql://root:supersecret@localhost:3306?ssl-mode=disabled")
      ensure
        teardown(p)
      end
    end

    it "lets an explicit login_user/login_password override the option file" do
      p = setup("[client]\nuser=\"root\"\npassword=\"fromfile\"\n")
      begin
        uri = Krikri::PluginHelpers::MysqlConnection.build_uri(user: "bob", password: "explicit", config_file: p)
        uri.must_equal("mysql://bob:explicit@localhost:3306?ssl-mode=disabled")
      ensure
        teardown(p)
      end
    end

    it "uses only user/password from the option file when login_host is explicit (host not overridden)" do
      p = setup("[client]\nuser=\"root\"\npassword=\"pw\"\nsocket=/run/mysqld/mysqld.sock\n")
      begin
        # login_host given => socket from the file is ignored, host honored,
        # but user/password still come from the file.
        uri = Krikri::PluginHelpers::MysqlConnection.build_uri(host: "db.example.com", config_file: p)
        uri.must_equal("mysql://root:pw@db.example.com:3306?ssl-mode=disabled")
      ensure
        teardown(p)
      end
    end

    it "does not honor a [client] socket when login_host is explicit" do
      PluginSpecHelper::ENV_MUTEX.synchronize do
        original_user = ENV["USER"]?
        ENV["USER"] = "specuser"
        p = setup("[client]\nsocket=/run/mysqld/mysqld.sock\n")
        begin
          # login_host given => socket ignored, host honored; no user in the
          # file, so the connection username falls back to the OS user.
          uri = Krikri::PluginHelpers::MysqlConnection.build_uri(host: "db", config_file: p)
          uri.must_equal("mysql://specuser@db:3306?ssl-mode=disabled")
        ensure
          teardown(p)
          ENV["USER"] = original_user if original_user
        end
      end
    end

    it "returns no error for a missing option file (treated as absent)" do
      PluginSpecHelper::ENV_MUTEX.synchronize do
        original_user = ENV["USER"]?
        ENV["USER"] = "specuser"
        begin
          uri = Krikri::PluginHelpers::MysqlConnection.build_uri(config_file: "/no/such/my.cnf")
          uri.must_equal("mysql://specuser@localhost:3306?ssl-mode=disabled")
        ensure
          ENV["USER"] = original_user if original_user
        end
      end
    end

    it "ignores comments and !includedir-style lines, and strips quotes" do
      p = setup("#comment\n[client]\n!includedir /etc/mysql/conf.d/\nuser=root\npassword='letmein'\nsocket=/tmp/mysql.sock\n")
      begin
        uri = Krikri::PluginHelpers::MysqlConnection.build_uri(config_file: p)
        uri.must_equal("mysql://root:letmein@/tmp/mysql.sock?ssl-mode=disabled")
      ensure
        teardown(p)
      end
    end

    it "uses defaults when the file has no [client] section" do
      PluginSpecHelper::ENV_MUTEX.synchronize do
        original_user = ENV["USER"]?
        ENV["USER"] = "specuser"
        p = setup("[mysqld]\nuser=someuser\npassword=whatever\n")
        begin
          uri = Krikri::PluginHelpers::MysqlConnection.build_uri(config_file: p)
          uri.must_equal("mysql://specuser@localhost:3306?ssl-mode=disabled")
        ensure
          teardown(p)
          ENV["USER"] = original_user if original_user
        end
      end
    end

    it "expands a leading ~ in the config_file using $HOME (matches os.path.expanduser)" do
      PluginSpecHelper::ENV_MUTEX.synchronize do
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
          uri = Krikri::PluginHelpers::MysqlConnection.build_uri(config_file: "~/.my.cnf")
          uri.must_equal("mysql://root:tildehome@localhost:3306?ssl-mode=disabled")
        ensure
          File.delete?(File.join(home, ".my.cnf"))
          Dir.delete?(home)
          ENV["USER"] = original_user if original_user
          ENV["HOME"] = original_home if original_home
        end
      end
    end
  end
end

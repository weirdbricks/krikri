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

  describe ".resolve_socket" do
    NO_DEFS = {user: nil, password: nil, socket: nil}

    it "keeps an explicit login_unix_socket no matter what else is set" do
      Krikri::PluginHelpers::MysqlConnection.resolve_socket("/explicit.sock", "localhost", NO_DEFS, exists: ->(_p : String) { true })
        .must_equal("/explicit.sock")
    end

    it "maps the implicit and the explicit 'localhost' login host to a default socket (libmariadb/MySQLdb semantics)" do
      # Only the first candidate that "exists" is picked; with a real
      # Debian-family MariaDB this is /var/run/mysqld/mysqld.sock, which is
      # how real ansible's mysql_user connects as root/'' (the Debian
      # root@localhost is native-'invalid'-OR-unix_socket, so TCP is denied
      # while the socket authenticates the OS root user via SO_PEERCRED -
      # round 2300215 fiaasco.mariadb).
      expected = Krikri::PluginHelpers::MysqlConnection::DEFAULT_SOCKET_CANDIDATES.first
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, nil, NO_DEFS, exists: ->(_p : String) { true })
        .must_equal(expected)
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, "localhost", NO_DEFS, exists: ->(_p : String) { true })
        .must_equal(expected)
    end

    it "picks the first candidate that exists, in order" do
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, "localhost", NO_DEFS, exists: ->(p : String) { p == "/var/lib/mysql/mysql.sock" })
        .must_equal("/var/lib/mysql/mysql.sock")
    end

    it "stays on TCP when no default socket exists (pure-TCP servers keep working)" do
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, nil, NO_DEFS, exists: ->(_p : String) { false })
        .must_be_nil
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, "localhost", NO_DEFS, exists: ->(_p : String) { false })
        .must_be_nil
    end

    it "does not map a non-localhost login host to a socket" do
      # host='127.0.0.1' is TCP even with sockets present (same denial real
      # ansible gets through MySQLdb for an explicit 127.0.0.1 login host).
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, "127.0.0.1", NO_DEFS, exists: ->(_p : String) { true })
        .must_be_nil
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, "db.example.com", NO_DEFS, exists: ->(_p : String) { true })
        .must_be_nil
    end

    it "prefers an option-file [client] socket over the default candidates" do
      defs = {user: "root", password: "pw", socket: "/mycnf.sock"}
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, nil, defs, exists: ->(_p : String) { true })
        .must_equal("/mycnf.sock")
    end

    it "still prefers an option-file socket only for localhost-style hosts" do
      defs = {user: "root", password: "pw", socket: "/mycnf.sock"}
      Krikri::PluginHelpers::MysqlConnection.resolve_socket(nil, "db.example.com", defs, exists: ->(_p : String) { true })
        .must_be_nil
    end
  end

  describe ".default_socket_file" do
    it "returns nil when none of the candidate paths exists" do
      Krikri::PluginHelpers::MysqlConnection.default_socket_file(exists: ->(_p : String) { false }).must_be_nil
    end

    it "scans the candidates in declaration order" do
      seen = [] of String
      result = Krikri::PluginHelpers::MysqlConnection.default_socket_file(exists: ->(p : String) { seen << p; p.ends_with?(".sock") && seen.size > 1 })
      result.must_equal(Krikri::PluginHelpers::MysqlConnection::DEFAULT_SOCKET_CANDIDATES[1])
      seen.first.must_equal(Krikri::PluginHelpers::MysqlConnection::DEFAULT_SOCKET_CANDIDATES[0])
    end

    it "falls back to the real filesystem check when no predicate is given" do
      # No MySQL server socket is expected on the test host; whatever the
      # real answer is, it must be one of the candidates.
      result = Krikri::PluginHelpers::MysqlConnection.default_socket_file
      if result
        Krikri::PluginHelpers::MysqlConnection::DEFAULT_SOCKET_CANDIDATES.must_include(result)
        File.exists?(result).must_equal(true)
      else
        Krikri::PluginHelpers::MysqlConnection::DEFAULT_SOCKET_CANDIDATES.each { |candidate| File.exists?(candidate).must_equal(false) }
      end
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

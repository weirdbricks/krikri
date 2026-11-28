require "../minitest_helper"

# AnsibleModule converts every type='int' parameter with decimal.Decimal, so
# `login_port: "1_000"` is port 1000 to real and a negative port is handed to
# PyMySQL, which fails the module in its own connection-failure wording. A
# spelling Crystal's #to_i cannot read used to reach
# MysqlConnection.build_base_uri raw and raised inside the plugin, so the task
# failed with the engine's internal-error wrapper ("Plugin execution failed:
# Invalid URI: bad port" / "Invalid Int32") instead (issue #1977).
#
# Real has no port range check in these four modules, so its failure is a live
# connect attempt whose errno text depends on what listens on the (possibly
# truncated) port: the deterministic negative-port and range-check parts are
# pinned as a divergence-corpus case
# (test/fixtures/divergence/1977-mysql-negative-login-port), and this test
# covers the dialling ports by their failure SHAPE (a module-level connection
# failure, never the plugin wrapper).
private MYSQL_PORT_PROJECT_ROOT = File.expand_path("../..", __DIR__)
private MYSQL_PORT_BINARY       = File.join(MYSQL_PORT_PROJECT_ROOT, "bin", "krikri-playbook")
private MYSQL_PORT_INVENTORY    = File.join(MYSQL_PORT_PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_mysql_port_playbook(yaml : String) : String
  playbook = File.tempname("mysql-login-port-text", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  Process.run(MYSQL_PORT_BINARY, ["-i", MYSQL_PORT_INVENTORY, playbook], output: output, error: output)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "mysql_* login_port text Ansible's int conversion accepts (issue #1977)" do
  # getaddrinfo refuses a negative service, so real never dials and the text
  # is host independent (live-verified vs ansible-core 2.21.6 /
  # ansible.mysql 5.2.0).
  EAI_SERVICE_TAIL = %((2003, "Can't connect to MySQL server on 'localhost' ([Errno -8] Servname not supported for ai_socktype)"))

  private def extra_params(plugin : String) : Hash(String, String)
    case plugin
    when "mysql_user"      then {"name" => "alice"}
    when "mysql_query"     then {"query" => "SELECT 1"}
    when "mysql_variables" then {"variable" => "max_connections"}
    else                        {} of String => String
    end
  end

  it "fails a negative login_port in the module's connection-failure wording" do
    {"mysql_user", "mysql_info", "mysql_query", "mysql_variables"}.each do |plugin|
      params = extra_params(plugin).merge({"login_user" => "root", "login_port" => "-5"})
      msg = PluginSpecHelper.run(plugin, params)["msg"].as_s
      msg.includes?("Plugin execution failed").must_equal(false, "#{plugin}: #{msg}")
      msg.ends_with?(EAI_SERVICE_TAIL).must_equal(true, "#{plugin}: #{msg}")
    end
  end

  it "accepts an underscored login_port as the decimal port real dials" do
    # Neither port has a listener in the suite's environments, so both
    # engines fail the module at connect; the point is that the plugin no
    # longer raises while building the URI.
    {"1_000", "1__0"}.each do |port|
      {"mysql_user", "mysql_info", "mysql_query", "mysql_variables"}.each do |plugin|
        params = extra_params(plugin).merge({"login_user" => "root", "login_port" => port})
        msg = PluginSpecHelper.run(plugin, params)["msg"].as_s
        msg.includes?("Plugin execution failed").must_equal(false, "#{plugin}/#{port}: #{msg}")
        msg.includes?("Exception message: (2003,").must_equal(true, "#{plugin}/#{port}: #{msg}")
      end
    end
  end

  it "accepts an underscored login_port in mysql_db's own range check and connect" do
    msg = PluginSpecHelper.run("mysql_db", {
      "name" => "somedb", "login_user" => "root", "login_port" => "1_000",
    })["msg"].as_s
    msg.includes?("Plugin execution failed").must_equal(false, msg)
    msg.includes?("login_port must be a valid unix port number").must_equal(false, msg)
  end

  it "keeps rejecting an out-of-range login_port in mysql_db, underscored or not" do
    # Real converts the text first (Decimal has no width), then runs its own
    # 0-65535 check, so any magnitude lands on the range message.
    {"-5", "-1_0", "99999999999999"}.each do |port|
      msg = PluginSpecHelper.run("mysql_db", {
        "name" => "somedb", "login_user" => "root", "login_port" => port,
      })["msg"].as_s
      msg.must_equal("login_port must be a valid unix port number (0-65535)")
    end
  end

  it "runs the controller's type conversion, like real, before reaching the plugin" do
    # `1.5` is not integral to Decimal, so real fails the argument spec and
    # never connects; a magnitude past Int32 must still convert (real's
    # conversion has no width) and land on mysql_db's own range message.
    output = run_mysql_port_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.mysql.mysql_user:
              name: alice
              login_user: root
              login_port: "1.5"
            ignore_errors: true
          - ansible.mysql.mysql_db:
              name: somedb
              login_user: root
              login_port: 99999999999999
            ignore_errors: true
      YAML
    output.must_include("argument 'login_port' is of type str and we were unable to convert to int")
    output.must_include("'1.5'")
    output.must_include("login_port must be a valid unix port number (0-65535)")
  end
end

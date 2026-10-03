require "../minitest_helper"
require "file_utils"
require "socket"

# Argument-spec parity for the postgresql_* / mysql_* plugin families,
# live-verified against ansible-playbook 2.19.11 + community.postgresql
# 4.2.0 / community.mysql 5.0.2 (which plugin_routing redirects to
# ansible.mysql 5.2.0) on this host, 2026-10-03.
#
# What this pins down (all confirmed by running both engines over the
# same playbooks):
#
#  - postgresql_query's argument_spec is the shared
#    postgres_common_argument_spec, so the deprecated `host:`,
#    `port:`, `login:`, `unix_socket:` and `db:` aliases ARE accepted
#    (krikri used to reject all five as unsupported parameters, unlike
#    every other community.postgresql plugin);
#  - mysql_query rejects `db:` (login_db has no alias) and mysql_user
#    rejects `user:` (name has no alias in ansible.mysql 5.2.0);
#  - mysql_query's argument_spec has session_vars (a list of dicts),
#    which krikri's spec table was missing from its
#    "Supported parameters include:" listing.
#
# Validation-only cases need no database: they only need the module to be
# REACHED (a connection failure afterwards is fine - real fails the same
# way). The one functional case runs against a real PostgreSQL server
# when one is listening on 127.0.0.1:35432 and skips otherwise.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private PG_PORT      = 35432

private def run_playbook(yaml : String) : String
  playbook = File.tempname("db-argspec-parity", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def pg_up? : Bool
  TCPSocket.new("127.0.0.1", PG_PORT, connect_timeout: 1).close
  true
rescue
  false
end

private def unsupported_for(output : String, mod_name : String) : String?
  output.split("\n").find { |line| line.includes?("Unsupported parameters for (#{mod_name}) module:") }
end

# Runs one task against `mod_name` with the given params and returns the
# whole run's output (whatever the task turned out to report).
private def task_msg(mod_name : String, params : String) : String
  body = params.split("\n").reject(&.empty?).map { |line| "            #{line}" }.join("\n")
  play = String.build do |io|
    io << "- hosts: localhost\n"
    io << "  connection: local\n"
    io << "  gather_facts: false\n"
    io << "  tasks:\n"
    io << "    - name: parity case\n"
    io << "      #{mod_name}:\n"
    io << body << "\n"
    io << "      ignore_errors: true\n"
  end
  run_playbook(play)
end

describe "db module argument-spec parity" do
  # --- accepted-but-there cases (krikri must not reject them) ---

  it "accepts postgresql_query's deprecated host/port/login/unix_socket/db aliases" do
    msg = task_msg("postgresql_query", <<-PARAMS)
      db: postgres
      host: 127.0.0.1
      port: #{PG_PORT}
      login: postgres
      login_password: krikri
      unix_socket: /var/run/postgresql
      query: "select 1"
    PARAMS
    unsupported_for(msg, "postgresql_query").must_be_nil
  end

  it "accepts postgresql_db/postgresql_user/postgresql_privs aliases too" do
    %w[postgresql_db postgresql_user postgresql_privs].each do |mod|
      msg = task_msg(mod, <<-PARAMS)
        host: 127.0.0.1
        port: #{PG_PORT}
        login: postgres
        login_password: krikri
        unix_socket: /var/run/postgresql
      PARAMS
      unsupported_for(msg, mod).must_be_nil
    end
  end

  it "accepts the mysql_* TLS aliases (ssl_cert/ssl_key/ssl_ca)" do
    %w[mysql_db mysql_info mysql_query mysql_user mysql_variables].each do |mod|
      msg = task_msg(mod, <<-PARAMS)
        login_user: root
        login_password: krikri
        ssl_ca: /nonexistent/ca.pem
        ssl_cert: /nonexistent/c.pem
        ssl_key: /nonexistent/k.pem
      PARAMS
      unsupported_for(msg, mod).must_be_nil
    end
  end

  # --- rejected-by-real cases (krikri must reject identically) ---

  it "rejects mysql_user's user: param, which real has no alias for" do
    msg = task_msg("mysql_user", <<-PARAMS)
      name: krikri_parity
      user: krikri_parity
      login_user: root
      login_password: krikri
    PARAMS
    unsupported_for(msg, "mysql_user").not_nil!.must_include("module: user.")
  end

  it "rejects mysql_query's db: param (login_db has no alias)" do
    msg = task_msg("mysql_query", <<-PARAMS)
      db: krikri_parity
      query: "select 1"
      login_user: root
      login_password: krikri
    PARAMS
    unsupported_for(msg, "mysql_query").not_nil!.must_include("module: db.")
  end

  it "lists session_vars among mysql_query's supported parameters" do
    msg = task_msg("mysql_query", <<-PARAMS)
      query: "select 1"
      login_user: root
      login_password: krikri
      krikri_bogus: 1
    PARAMS
    msg.must_include("query, session_vars, single_transaction (ssl_ca, ssl_cert, ssl_key).")
  end

  it "names postgresql_query without its collection prefix, like real" do
    msg = task_msg("postgresql_query", <<-PARAMS)
      query: "select 1"
      krikri_bogus: 1
    PARAMS
    unsupported_for(msg, "postgresql_query").not_nil!.must_include(
      "module: krikri_bogus. Supported parameters include: autocommit, ca_cert, connect_params, " \
      "encoding, login_db, login_host, login_password, login_port, login_unix_socket, login_user, " \
      "named_args, positional_args, query, search_path, session_role, ssl_cert, ssl_key, ssl_mode, " \
      "trust_input (db, host, login, port, ssl_rootcert, unix_socket).",
    )
  end

  # --- functional: the alias must connect, not just validate ---

  it "runs postgresql_query against a real server through the port:/db: aliases" do
    skip "no PostgreSQL on 127.0.0.1:#{PG_PORT}" unless pg_up?
    play = String.build do |io|
      io << "- hosts: localhost\n"
      io << "  connection: local\n"
      io << "  gather_facts: false\n"
      io << "  tasks:\n"
      io << "    - name: alias query\n"
      io << "      postgresql_query:\n"
      io << "        db: postgres\n"
      io << "        host: 127.0.0.1\n"
      io << "        port: #{PG_PORT}\n"
      io << "        login_user: postgres\n"
      io << "        login_password: krikri\n"
      io << "        query: \"select 1 as x\"\n"
      io << "      register: q\n"
      io << "      ignore_errors: true\n"
      io << "    - name: show result\n"
      io << "      debug:\n"
      io << "        var: q\n"
    end
    output = run_playbook(play)
    output.must_include("query_result")
    output.must_include("\"x\": 1")
    output.wont_include("Unsupported parameters")
  end
end

require "../minitest_helper"

require "socket"

# caching_sha2_password FULL authentication over a plain, unencrypted TCP
# connection: the MySQL 8 default for root@%, exercised against a real
# MySQL 8.4 server.
#
# A freshly started server has an empty authentication cache, so the very
# first TCP connection has to complete the full (RSA) exchange rather than
# the fast path. Every spec here therefore clears that cache first with
# FLUSH PRIVILEGES - issued through the container's own client, exactly the
# step that empties the server-side auth cache - so krikri's mysql_* plugin
# is the first client over TCP since, and the fast-auth shortcut cannot
# mask a broken full-auth implementation.
#
# The throwaway container:
#   podman run -d --name krikri-kp-mysql -e MYSQL_ROOT_PASSWORD=krikri \   (any name works)
#     -p 127.0.0.1:33306:3306 docker.io/library/mysql:8.4
# Every spec skips when it isn't running.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private MYSQL_HOST = "127.0.0.1"
private MYSQL_PORT = 33306

private def mysql_reachable? : Bool
  sock = TCPSocket.new(MYSQL_HOST, MYSQL_PORT, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

private def mysql_login_args(indent : Int32 = 0) : String
  [
    "login_host: #{MYSQL_HOST}",
    "login_port: #{MYSQL_PORT}",
    "login_user: root",
    "login_password: krikri",
  ].join("\n" + " " * indent)
end

# Empties the server's authentication cache, so the next TCP connection
# has to do caching_sha2_password's full (RSA) authentication instead of
# the fast path. Uses the container's own client - the host's mysql CLI
# cannot authenticate to a MySQL 8.4 server with caching_sha2_password.
private def flush_auth_cache : Nil
  # Find the container by the port it publishes (not by a fixed name), so any
  # throwaway MySQL 8.4 container serving 127.0.0.1:#{MYSQL_PORT} works. (podman's
  # `ps --filter publish=` does not exist, so read the Ports column.)
  names = IO::Memory.new
  Process.run("podman", ["ps", "--format", "{{.Names}}\t{{.Ports}}"],
    output: names, error: Process::Redirect::Close)
  container = names.to_s.lines.compact_map do |line|
    name, ports = line.split('\t', 2)
    name if ports && ports.includes?(":#{MYSQL_PORT}->")
  end.first? || raise "no podman container publishes port #{MYSQL_PORT} - cannot FLUSH PRIVILEGES"
  output = IO::Memory.new
  status = Process.run("podman",
    ["exec", container, "mysql", "-uroot", "-pkrikri", "-e", "FLUSH PRIVILEGES"],
    output: output, error: output)
  raise "FLUSH PRIVILEGES failed: #{output}" unless status.success?
end

private def query_dump(query : String) : JSON::Any
  flush_auth_cache
  dump = PluginSpecHelper.tmp_path("mysql-auth-dump.json")
  playbook = File.tempname("mysql-auth", ".yml")
  File.write(playbook, "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" +
                       "    - name: query\n      community.mysql.mysql_query:\n" +
                       "        query: \"#{query}\"\n        #{mysql_login_args(8)}\n      register: r\n" +
                       "    - name: dump\n      ansible.builtin.copy:\n        dest: #{dump}\n" +
                       "        content: |-\n          {{ r | to_json }}\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
  JSON.parse(File.read(dump))
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "mysql full authentication over plain TCP" do
  it "authenticates a query on the first connection after the auth cache was flushed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = query_dump("SELECT 1 AS one")
    dump["failed"].as_bool.must_equal(false)
    dump["executed_queries"].as_a.map(&.as_s).must_equal(["SELECT 1 AS one"])
    dump["query_result"].as_a.first.as_a.first["one"].as_i.must_equal(1)
  end

  # Same exchange through a different plugin, so the fix cannot be specific
  # to mysql_query's code path.
  it "authenticates mysql_info on the first connection after the auth cache was flushed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    flush_auth_cache
    dump_path = PluginSpecHelper.tmp_path("mysql-auth-info-dump.json")
    playbook = File.tempname("mysql-auth-info", ".yml")
    File.write(playbook, "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" +
                         "    - name: info\n      community.mysql.mysql_info:\n        filter: version\n" +
                         "        #{mysql_login_args(8)}\n      register: r\n" +
                         "    - name: dump\n      ansible.builtin.copy:\n        dest: #{dump_path}\n" +
                         "        content: |-\n          {{ r | to_json }}\n")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
    dump = JSON.parse(File.read(dump_path))
    dump["failed"].as_bool.must_equal(false)
    dump["server_engine"].as_s.must_equal("MySQL")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # A wrong password must still be rejected (the RSA exchange must not
  # authenticate anything at all).
  it "rejects a wrong password after the auth cache was flushed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    flush_auth_cache
    playbook = File.tempname("mysql-auth-bad", ".yml")
    File.write(playbook, "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" +
                         "    - name: query\n      community.mysql.mysql_query:\n" +
                         "        login_host: #{MYSQL_HOST}\n        login_port: #{MYSQL_PORT}\n" +
                         "        login_user: root\n        login_password: definitely-not-the-password\n" +
                         "        query: \"SELECT 1 AS one\"\n      ignore_errors: true\n      register: r\n")
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    output.to_s.must_include("Access denied")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

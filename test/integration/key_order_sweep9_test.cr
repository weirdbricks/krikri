require "../minitest_helper"

require "socket"

# Registered-result key order for the mysql_variables plugin, pinned to the
# order live-verified against real ansible-playbook 2.19.11 with
# community.mysql 5.0.2 (which redirects the call to ansible.mysql 5.2.0)
# against a real MySQL 8.4.11 server, observed through `{{ r | to_json }}`
# on a registered task - the -v dump sorts alphabetically, so the order is
# only observable programmatically (see key_order_sweep_test.cr for the
# general method).
#
# The four shapes the real module has:
# - a variable change (mode global/persist/persist_only): msg, changed,
#   queries, failed - `queries` carries the executed SET GLOBAL statement
#   and is absent on the "already set" no-op, which registers
#   msg, changed, failed;
# - the read-only form (no `value:`): msg, failed, changed - the module
#   passes neither changed nor queries to exit_json there, so the
#   controller backfills both AFTER the module dict, unlike the change
#   path where `changed` is a real module kwarg and leads `queries`;
# - check mode: the module declares no check-mode support, so the
#   controller short-circuits with skipped, msg, failed, changed;
# - an unknown variable name: the module's own fail_json passes
#   changed=False explicitly, so `changed` LEADS - unlike the arg-spec
#   and connection failures, which are plain fail_json and keep the
#   shared default failed, msg, changed, exception order (not pinned
#   here: that default has its own specs).
#
# `deprecations`, which real's registered result also carries after
# `failed`, is the collection-version redirect community.mysql ->
# ansible.mysql emitted by the collection loader, not part of the
# module's own result dict; krikri dispatches the module directly and
# does not carry it.
#
# The other four mysql plugins of this sweep got no pin HERE because
# their key sets diverged at the time - key_order cannot conjure a key
# the plugin never emits. mysql_db, mysql_query and mysql_user have since
# been brought onto real's key sets; their pins (and the values behind
# them) live in mysql_result_shape_test.cr. mysql_info still emits only
# version and settings where real registers a dozen more, so it is still
# unpinned.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private MYSQL_HOST = "127.0.0.1"
private MYSQL_PORT = 33306

# The throwaway MySQL container this sweep verified against: podman run -d
# --name krikri-kp-mysql -e MYSQL_ROOT_PASSWORD=krikri -p
# 127.0.0.1:33306:3306 docker.io/library/mysql:8.4. Every play below
# skips when it isn't running.
private def mysql_reachable? : Bool
  sock = TCPSocket.new(MYSQL_HOST, MYSQL_PORT, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump9.json")
  playbook = File.tempname("key-order-sweep9", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Wraps `task` (one module call plus its register) in a play whose last
# task dumps the registered result's key order.
# Runs a playbook whose result nothing reads - used for the setup run
# that has to put the server in the state the spec then asserts on.
private def run_play(yaml : String) : Nil
  playbook = File.tempname("key-order-sweep9-setup", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def registered_dump_play(task : String) : String
  preamble = "- hosts: localhost\n" \
             "  gather_facts: false\n" \
             "  connection: local\n" \
             "  tasks:\n"
  dump = "    - name: dump\n" \
         "      ansible.builtin.copy:\n" \
         "        dest: KRIKRI_DUMP_PATH\n" \
         "        content: |-\n" \
         "          {{ r | to_json }}\n"
  # The task bodies are written as heredocs inside already-indented `it`
  # blocks, so they arrive indented by an arbitrary common amount. YAML
  # cares only about the RELATIVE shape: re-anchor whatever the common
  # indent turns out to be to the 4 spaces a `tasks:` list item needs.
  lines = task.lines.reject(&.strip.empty?)
  common = lines.min_of { |line| line.size - line.lstrip.size }
  # Drop exactly the common prefix (not lstrip: nesting inside the task
  # body is relative and must survive), then re-anchor to 4 spaces.
  body = lines.map { |line| "    " + line.byte_slice(common, line.bytesize) + "\n" }.join
  preamble + body + dump
end

describe "mysql_variables plugin result key order (sweep9)" do
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

  # The change path and the "already set" no-op share one exit_json shape,
  # differing only in whether `queries` is present - so a single
  # SUCCESS_KEY_ORDER covers both. max_connections defaults to 151, so
  # 222 is a real change.
  it "registers a variable change as msg, changed, queries, failed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    keys = run_registered_dump(<<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: move max_connections off the target
            community.mysql.mysql_variables:
              variable: max_connections
              value: "250"
              login_host: #{MYSQL_HOST}
              login_port: #{MYSQL_PORT}
              login_user: root
              login_password: krikri
            register: pre
          - name: set max_connections
            community.mysql.mysql_variables:
              variable: max_connections
              value: "222"
              login_host: #{MYSQL_HOST}
              login_port: #{MYSQL_PORT}
              login_user: root
              login_password: krikri
            register: r
          - name: dump
            ansible.builtin.copy:
              dest: KRIKRI_DUMP_PATH
              content: |-
                {{ r | to_json }}
    YAML
    keys.must_equal(%w[msg changed queries failed])
  end

  it "registers the already-set no-op as msg, changed, failed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    # Drive the change to 222 first, so the no-op below is genuine and
    # independent of the previous spec's ordering.
    run_play(<<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: set max_connections
            community.mysql.mysql_variables:
              variable: max_connections
              value: "222"
              login_host: #{MYSQL_HOST}
              login_port: #{MYSQL_PORT}
              login_user: root
              login_password: krikri
            register: r
    YAML
    keys = run_registered_dump(registered_dump_play(<<-YAML))
            - name: set max_connections again
              community.mysql.mysql_variables:
                variable: max_connections
                value: "222"
                login_host: #{MYSQL_HOST}
                login_port: #{MYSQL_PORT}
                login_user: root
                login_password: krikri
              register: r
    YAML
    keys.must_equal(%w[msg changed failed])
  end

  # The read-only form's whole distinction is that `changed` trails
  # `failed`. This is the one shape where krikri needs failed_flag, or
  # its own failed: false would be absent from the wire dict and the
  # executor's backfill would land after `changed` instead.
  it "registers the read-only form as msg, failed, changed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    keys = run_registered_dump(registered_dump_play(<<-YAML))
            - name: read max_connections
              community.mysql.mysql_variables:
                variable: max_connections
                login_host: #{MYSQL_HOST}
                login_port: #{MYSQL_PORT}
                login_user: root
                login_password: krikri
              register: r
    YAML
    keys.must_equal(%w[msg failed changed])
  end

  it "registers a check-mode run as skipped, msg, failed, changed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    keys = run_registered_dump(registered_dump_play(<<-YAML))
            - name: check-mode set
              community.mysql.mysql_variables:
                variable: max_connections
                value: "222"
                login_host: #{MYSQL_HOST}
                login_port: #{MYSQL_PORT}
                login_user: root
                login_password: krikri
              check_mode: true
              register: r
    YAML
    keys.must_equal(%w[skipped msg failed changed])
  end

  # The module's own fail_json for an unknown variable passes
  # changed=False explicitly, so `changed` leads instead of trailing.
  it "registers an unknown variable failure as changed, failed, msg, exception" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    keys = run_registered_dump(<<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: set an unknown variable
            community.mysql.mysql_variables:
              variable: krikri_no_such_variable_xyz
              value: "1"
              login_host: #{MYSQL_HOST}
              login_port: #{MYSQL_PORT}
              login_user: root
              login_password: krikri
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              dest: KRIKRI_DUMP_PATH
              content: |-
                {{ r | to_json }}
    YAML
    keys.must_equal(%w[changed failed msg exception])
  end
end

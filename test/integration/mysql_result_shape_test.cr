require "../minitest_helper"

require "socket"

# Registered-result SHAPE (keys, values and wire order) for the
# community.mysql plugins, pinned to real ansible-playbook 2.19.11 with
# community.mysql 5.0.2 against a real MySQL 8.4 server, observed through
# `{{ r | to_json }}` on a registered task (the -v dump sorts
# alphabetically, so the order is only observable programmatically - see
# key_order_sweep9_test.cr for the general method). Real's registered
# result also carries `deprecations` after `failed` - that is the
# collection-version redirect community.mysql -> ansible.mysql emitted by
# the collection loader, not part of the module's own result dict, so it
# is not asserted here.
#
# These specs assert VALUES too, not just the key set: real echoes the
# `name:`/`user:` parameter back and reports the exact SQL statement(s) it
# executed (`executed_commands`/`executed_queries`), so a plugin that
# emits the right keys with plausible-but-different content is still
# caught here.
#
# The throwaway MySQL container everything below was verified against:
#   podman run -d --name krikri-kp-mysql -e MYSQL_ROOT_PASSWORD=krikri \
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

# The login_* block, with every line after the first carrying *indent*
# spaces - the indentation the surrounding YAML text uses for the
# module's params, so the block survives #task_body's re-anchoring. The
# first line carries none, so it drops straight into an interpolated
# heredoc as "#{mysql_login_args(12)}" at whatever indent it already has.
private def mysql_login_args(indent : Int32 = 0) : String
  [
    "login_host: #{MYSQL_HOST}",
    "login_port: #{MYSQL_PORT}",
    "login_user: root",
    "login_password: krikri",
  ].join("\n" + " " * indent)
end

# Runs a play whose last task copies `{{ r | to_json }}` into a file,
# then returns the parsed dump (writing it through copy: avoids the
# display layer's JSON escaping entirely). `setup:` runs first as a
# separate play, for the pre-run that has to put the server in the state
# the spec then asserts on.
private def registered_dump(tasks : String, setup : String? = nil) : JSON::Any
  run_play(setup) if setup
  dump = PluginSpecHelper.tmp_path("mysql-shape-dump.json")
  playbook = File.tempname("mysql-result-shape", ".yml")
  File.write(playbook, "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" +
                       tasks + "    - name: dump\n      ansible.builtin.copy:\n        dest: #{dump}\n" +
                       "        content: |-\n          {{ r | to_json }}\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
  JSON.parse(File.read(dump))
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def run_play(yaml : String) : Nil
  playbook = File.tempname("mysql-result-shape-setup", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# A play that only drops the databases these specs create, so each spec
# starts from the same known state regardless of minitest's randomized
# order or an interrupted earlier run.
private def drop_dbs_play(*names : String) : String
  drop = names.map { |db| "          - \"drop database if exists `#{db}`\"" }.join("\n")
  "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" \
  "    - name: drop\n      community.mysql.mysql_query:\n        query:\n#{drop}\n" \
  "        #{mysql_login_args(8)}\n"
end

# A play that creates one database, for a spec that needs the server to
# start out already in that state.
private def create_db_play(name : String) : String
  "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" \
  "    - name: create\n      community.mysql.mysql_db:\n        name: #{name}\n        state: present\n" \
  "        #{mysql_login_args(8)}\n"
end

private MYSQL_TEST_DB = "shape_krdb"

# A play creating the scratch table the DML spec updates.
private def setup_table_play : String
  run_play(drop_dbs_play(MYSQL_TEST_DB))
  "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" \
  "    - name: setup\n      community.mysql.mysql_db:\n        name: #{MYSQL_TEST_DB}\n        state: present\n" \
  "        #{mysql_login_args(8)}\n" \
  "    - name: table\n      community.mysql.mysql_query:\n" \
  "        query: \"create table #{MYSQL_TEST_DB}.t1 (i int)\"\n        #{mysql_login_args(8)}\n"
end

private def drop_users_play(*names : String) : String
  drops = names.map do |account|
    "          - \"drop user if exists '#{account}'@'localhost'\""
  end.join("\n")
  "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" \
  "    - name: drop users\n      community.mysql.mysql_query:\n        query:\n#{drops}\n" \
  "        #{mysql_login_args(8)}\n"
end

private def create_user_play(name : String) : String
  run_play(drop_users_play(name))
  "- hosts: localhost\n  gather_facts: false\n  connection: local\n  tasks:\n" \
  "    - name: create\n      community.mysql.mysql_user:\n        name: \"#{name}\"\n" \
  "        #{mysql_login_args(8)}\n"
end

# Re-anchors an indented heredoc body (which arrives indented by an
# arbitrary common amount) to the 4 spaces a `tasks:` list item needs.
private def task_body(text : String) : String
  lines = text.lines.reject(&.strip.empty?)
  common = lines.min_of { |line| line.size - line.lstrip.size }
  lines.map { |line| "    " + line.byte_slice(common, line.bytesize) + "\n" }.join
end

describe "mysql_db plugin result shape" do
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

  # Real's exit_json for present/absent carries no `msg` key at all, and
  # reports `executed_commands` as the mogrified statement it ran.
  it "registers a create as changed, db, db_list, executed_commands, failed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    run_play(drop_dbs_play("shape_db1"))
    dump = registered_dump(task_body(<<-YAML), drop_dbs_play("shape_db1"))
            - name: create
              community.mysql.mysql_db:
                name: shape_db1
                state: present
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed db db_list executed_commands failed])
    dump["changed"].as_bool.must_equal(true)
    dump["db"].as_s.must_equal("shape_db1")
    dump["db_list"].as_a.map(&.as_s).must_equal(["shape_db1"])
    dump["executed_commands"].as_a.map(&.as_s).must_equal(["CREATE DATABASE `shape_db1`"])
  end

  # The idempotent no-op still reports `executed_commands`, as an empty
  # list (real only ever leaves the key out in check mode).
  it "registers the already-present no-op with an empty executed_commands" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), create_db_play("shape_db2"))
            - name: create
              community.mysql.mysql_db:
                name: shape_db2
                state: present
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed db db_list executed_commands failed])
    dump["changed"].as_bool.must_equal(false)
    dump["executed_commands"].as_a.size.must_equal(0)
  end

  # Real returns a DIFFERENT exit_json in check mode, before
  # `executed_commands` is ever populated - so the key is absent there
  # even on a run that would have changed something.
  it "registers a check-mode create without executed_commands" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), drop_dbs_play("shape_db3"))
            - name: create
              community.mysql.mysql_db:
                name: shape_db3
                state: present
                #{mysql_login_args(12)}
              register: r
              check_mode: true
    YAML
    dump.as_h.keys.must_equal(%w[changed db db_list failed])
    dump["changed"].as_bool.must_equal(true)
  end

  it "registers a drop as changed, db, db_list, executed_commands, failed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), drop_dbs_play("shape_db4"))
            - name: create
              community.mysql.mysql_db:
                name: shape_db4
                state: present
                #{mysql_login_args(12)}
            - name: drop
              community.mysql.mysql_db:
                name: shape_db4
                state: absent
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed db db_list executed_commands failed])
    dump["changed"].as_bool.must_equal(true)
    dump["executed_commands"].as_a.map(&.as_s).must_equal(["DROP DATABASE `shape_db4`"])
  end

  # Real's `name:` is a list: `db` is the names joined by a space and
  # `db_list` the list itself, and one statement is reported per created
  # database - with `encoding:`/`collation:` reaching the statement as
  # the quoted string literals real binds them as.
  it "registers a multi-name create with both name shapes and one statement per database" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), drop_dbs_play("shape_db5", "shape_db6"))
            - name: create
              community.mysql.mysql_db:
                name:
                  - shape_db5
                  - shape_db6
                state: present
                encoding: utf8mb4
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed db db_list executed_commands failed])
    dump["db"].as_s.must_equal("shape_db5 shape_db6")
    dump["db_list"].as_a.map(&.as_s).must_equal(%w[shape_db5 shape_db6])
    dump["executed_commands"].as_a.map(&.as_s).must_equal([
      "CREATE DATABASE `shape_db5` CHARACTER SET 'utf8mb4'",
      "CREATE DATABASE `shape_db6` CHARACTER SET 'utf8mb4'",
    ])
  end
end

describe "mysql_query plugin result shape" do
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

  # Real passes no `msg` on success; `execution_time_ms` is a per
  # statement float (milliseconds, 4 decimals) that cannot be asserted
  # exactly - only its presence and per-statement arity.
  it "registers a select as changed, executed_queries, query_result, rowcount, execution_time_ms, failed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: select
              community.mysql.mysql_query:
                query: "select 1 as a"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed executed_queries query_result rowcount execution_time_ms failed])
    dump["changed"].as_bool.must_equal(false)
    dump["executed_queries"].as_a.map(&.as_s).must_equal(["select 1 as a"])
    dump["query_result"].as_a.map { |rows| rows.as_a.map(&.as_h["a"].as_i) }.must_equal([[1]])
    dump["rowcount"].as_a.map(&.as_i).must_equal([1])
    dump["execution_time_ms"].as_a.size.must_equal(1)
  end

  # One entry per statement in every list, in execution order.
  it "registers one entry per statement for a multi-statement query" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: two selects
              community.mysql.mysql_query:
                query:
                  - "select 1 as a"
                  - "select 2 as b"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed executed_queries query_result rowcount execution_time_ms failed])
    dump["executed_queries"].as_a.map(&.as_s).must_equal(["select 1 as a", "select 2 as b"])
    dump["rowcount"].as_a.map(&.as_i).must_equal([1, 1])
    dump["execution_time_ms"].as_a.size.must_equal(2)
  end

  # DDL always counts as changed; a DML statement's own rowcount decides,
  # and the no-rows DML is the unchanged case.
  it "registers a DML statement with no affected rows as unchanged" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), setup_table_play)
            - name: update nothing
              community.mysql.mysql_query:
                query: "update #{MYSQL_TEST_DB}.t1 set i = 5 where i = 99"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed executed_queries query_result rowcount execution_time_ms failed])
    dump["changed"].as_bool.must_equal(false)
    dump["rowcount"].as_a.map(&.as_i).must_equal([0])
  end
end

describe "mysql_user plugin result shape" do
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

  # Real's own user_add branch: `user` is the `name:` param echoed
  # verbatim, `password_changed` is true for the create, null for a
  # check-mode create (nothing was attempted), and `attributes` is null
  # unless `attributes:` was given. Each spec owns its own account, so
  # minitest's randomized order cannot make one spec's setup land inside
  # another's window.
  it "registers a create as changed, user, msg, password_changed, attributes, failed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), drop_users_play("kru_create@localhost"))
            - name: create
              community.mysql.mysql_user:
                name: "kru_create@localhost"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed user msg password_changed attributes failed])
    dump["changed"].as_bool.must_equal(true)
    dump["user"].as_s.must_equal("kru_create@localhost")
    dump["msg"].as_s.must_equal("User added")
    dump["password_changed"].as_bool.must_equal(true)
    dump["attributes"].raw.must_be_nil
  end

  it "registers the idempotent rerun as unchanged with password_changed false" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), create_user_play("kru_rerun@localhost"))
            - name: create again
              community.mysql.mysql_user:
                name: "kru_rerun@localhost"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed user msg password_changed attributes failed])
    dump["changed"].as_bool.must_equal(false)
    dump["msg"].as_s.must_equal("User unchanged")
    dump["password_changed"].as_bool.must_equal(false)
  end

  it "registers a delete and the already-absent no-op with real's wording" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), create_user_play("kru_delete@localhost"))
            - name: delete
              community.mysql.mysql_user:
                name: "kru_delete@localhost"
                state: absent
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed user msg password_changed attributes failed])
    dump["changed"].as_bool.must_equal(true)
    dump["msg"].as_s.must_equal("User deleted")
    dump["password_changed"].as_bool.must_equal(false)

    dump = registered_dump(task_body(<<-YAML), drop_users_play("kru_delete@localhost"))
            - name: delete again
              community.mysql.mysql_user:
                name: "kru_delete@localhost"
                state: absent
                #{mysql_login_args(12)}
              register: r
    YAML
    dump["changed"].as_bool.must_equal(false)
    dump["msg"].as_s.must_equal("User doesn't exist")
    dump["password_changed"].as_bool.must_equal(false)
  end

  # The check-mode create is the one path where real reports
  # `password_changed` as null rather than a boolean.
  it "registers a check-mode create with a null password_changed" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML), drop_users_play("kru_check@localhost"))
            - name: create
              community.mysql.mysql_user:
                name: "kru_check@localhost"
                #{mysql_login_args(12)}
              register: r
              check_mode: true
    YAML
    dump.as_h.keys.must_equal(%w[changed user msg password_changed attributes failed])
    dump["changed"].as_bool.must_equal(true)
    dump["user"].as_s.must_equal("kru_check@localhost")
    dump["password_changed"].raw.must_be_nil
  end
end

describe "mysql_info plugin result shape" do
  # Shared external DB state (fixed table/role/db names): never run in parallel with
  # sibling workers (see test/minitest_helper.cr).
  serial!

  # Real's exit_json always leads with the three server/connector facts
  # and then appends exactly the subsets the filter kept, in the order
  # its own dict declares them.
  it "registers every subset, in real's order, with no filter" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: everything
              community.mysql.mysql_info:
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[
      changed server_engine connector_name connector_version
      version databases settings global_status engines
      users users_info master_status slave_hosts slave_status failed
    ])
    dump["changed"].as_bool.must_equal(false)
    dump["server_engine"].as_s.must_equal("MySQL")
    # `version` is a dict whose own key order is real's dict(...) order.
    dump["version"].as_h.keys.must_equal(%w[major minor release suffix full])
    # Empty on a standalone server - real reports them as empty dicts, not
    # by omitting the keys.
    dump["slave_hosts"].as_h.must_be_empty
    dump["slave_status"].as_h.must_be_empty
    (dump["settings"].as_h["max_connections"].as_i > 0).must_equal(true)
    dump["users"].as_h.keys.sort!.must_equal(["%", "localhost"])
    (dump["users_info"].as_a.size > 0).must_equal(true)
  end

  it "registers only the filtered subset, still led by the connector facts" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: version only
              community.mysql.mysql_info:
                filter: version
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed server_engine connector_name connector_version version failed])
  end

  # A YAML list of subset names: real's argspec types `filter` as a list,
  # so both spellings reach the same code.
  it "registers only the listed subsets for a YAML list filter" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: version and databases
              community.mysql.mysql_info:
                filter:
                  - version
                  - databases
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed server_engine connector_name connector_version version databases failed])
  end

  # The same list reaching the plugin through a variable (`filter: "{{ var }}"`)
  # or a templated args dict arrives as JSON array text, not the literal
  # list's comma-joined form - both must filter identically.
  it "registers only the listed subsets for a list filter passed through a variable" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: version and databases via a variable
              community.mysql.mysql_info:
                filter: "{{ ['version', 'databases'] }}"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed server_engine connector_name connector_version version databases failed])
  end

  # Real's comma-separated string form of the same list.
  it "registers only the comma-separated subsets for a string filter" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: version and databases
              community.mysql.mysql_info:
                filter: version, databases
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed server_engine connector_name connector_version version databases failed])
  end

  # Real's `!name` exclusion form as a list, and the rule that an
  # inclusion alongside an exclusion makes the exclusion irrelevant.
  it "registers every subset but settings and engines for a list of exclusions" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: all but settings and engines
              community.mysql.mysql_info:
                filter:
                  - "!settings"
                  - "!engines"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[
      changed server_engine connector_name connector_version
      version databases global_status
      users users_info master_status slave_hosts slave_status failed
    ])
  end

  # A filter element that is not a subset name: real warns per element
  # (in the order given) and ignores it.
  it "warns and ignores an unknown filter element" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: version with a bogus element
              community.mysql.mysql_info:
                filter:
                  - version
                  - bogus
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[changed server_engine connector_name connector_version version failed warnings])
    dump["warnings"].as_a.map(&.as_s).must_equal(["filter element: bogus is not allowable, ignored"])
  end

  # Real's `!name` exclusion form, and its rule that any inclusion makes
  # the exclusions irrelevant.
  it "registers every subset but settings for filter '!settings'" do
    skip "no MySQL server at #{MYSQL_HOST}:#{MYSQL_PORT}" unless mysql_reachable?
    dump = registered_dump(task_body(<<-YAML))
            - name: all but settings
              community.mysql.mysql_info:
                filter: "!settings"
                #{mysql_login_args(12)}
              register: r
    YAML
    dump.as_h.keys.must_equal(%w[
      changed server_engine connector_name connector_version
      version databases global_status engines
      users users_info master_status slave_hosts slave_status failed
    ])
  end
end

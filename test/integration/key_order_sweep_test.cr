require "../minitest_helper"
require "http/server"
require "file_utils"

# Registered-result key orders for the ping/getent/debug/set_fact/assert/
# find/fetch/wait_for/unarchive/archive/uri plugins, pinned to the orders
# live-verified against real ansible-core 2.19.11 by registering each
# module's result and dumping `{{ r | to_json }}` (the -v dump sorts
# alphabetically, so the order is only observable programmatically).
#
# Module-plugin specs assert the plugin's own wire shape via
# PluginSpecHelper.run - krikri's successful module wire omits failed:
# false (real's registered result carries it, appended after the module
# dict), and for the modules whose real wire also carries no changed
# (ping/getent/wait_for: exit_json passes none, so real's task executor
# backfills the failed, changed TAIL on register) krikri's wire omits
# changed too (omit_changed), giving the registered shape ping/...,
# failed, changed. Action-plugin specs (debug/set_fact/assert) run the
# compiled binary against a real playbook and assert the REGISTERED
# shape, which for those controller-computed results does carry
# failed: false.
#
# fetch's check-mode and already-present shapes, wait_for's check-mode
# skip and the port/timeout-only/absent wait variants, unarchive's
# already-extracted rerun, archive's rerun and single-file compress, and
# uri's GET/return_content/dest/check-mode variants were all verified
# live per variant; find has no changed/check-mode shape difference
# (both live-verified identical).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump.json")
  playbook = File.tempname("key-order-sweep", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Stateful fixtures (fetch/unarchive/archive) need a fresh location per
# run - a leftover extract/archive from an earlier invocation would flip
# the changed flag and with it the asserted shape.
private def unique_tmp(*parts : String) : String
  PluginSpecHelper.tmp_path("#{parts.join("-")}-#{Random::Secure.hex(4)}")
end

describe "ping plugin result key order" do
  it "serializes a wire of just ping (real's module wire carries no changed)" do
    result = PluginSpecHelper.run("ping", {} of String => String)
    result["ping"].as_s.must_equal("pong")
    result.as_h.keys.must_equal(["ping"])
  end

  it "registers as ping, failed, changed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: ping it
            ansible.builtin.ping:
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["ping", "failed", "changed"])
  end
end

describe "getent plugin result key order" do
  it "serializes a passwd hit with ansible_facts leading (wire: ansible_facts, invocation)" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "root"})
    result.as_h.keys.must_equal(["ansible_facts", "invocation"])
  end

  it "serializes the fail_key-false not-found hit with msg after ansible_facts (wire: ansible_facts, msg, invocation)" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "krikri_no_such_user_9x7", "fail_key" => "false"})
    result["msg"].as_s.must_equal("One or more supplied key could not be found in the database.")
    result.as_h.keys.must_equal(["ansible_facts", "msg", "invocation"])
  end

  it "registers a passwd hit as ansible_facts, failed, changed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: getent it
            ansible.builtin.getent:
              database: passwd
              key: root
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["ansible_facts", "failed", "changed"])
  end
end

describe "find plugin result key order" do
  it "serializes a match in real find's order (files, changed, msg, matched, examined, skipped_paths)" do
    dir = PluginSpecHelper.tmp_path("find-order")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.txt"), "x")
    File.write(File.join(dir, "b.txt"), "y")

    result = PluginSpecHelper.run("find", {"paths" => dir, "patterns" => "*.txt"})
    result["changed"].as_bool.must_equal(false)
    result["matched"].as_i.must_equal(2)
    result.as_h.keys.must_equal(["files", "changed", "msg", "matched", "examined", "skipped_paths"])
  ensure
    FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
  end
end

describe "fetch plugin result key order" do
  it "serializes a transferred file as changed, md5sum, dest, remote_md5sum, checksum, remote_checksum" do
    src = unique_tmp("fetch-order-src-txt")
    dest = unique_tmp("fetch-order-dest")
    File.write(src, "fetch order\n")

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => dest, "flat" => "true"}, host_name: "localhost")
    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "md5sum", "dest", "remote_md5sum", "checksum", "remote_checksum"])
  ensure
    FileUtils.rm_r(dest) if dest && Dir.exists?(dest)
  end

  it "serializes the already-present rerun as changed, md5sum, file, dest, checksum" do
    src = unique_tmp("fetch-order2-src-txt")
    dest = unique_tmp("fetch-order2-dest")
    File.write(src, "fetch order again\n")
    PluginSpecHelper.run("fetch", {"src" => src, "dest" => dest, "flat" => "true"}, host_name: "localhost")
    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => dest, "flat" => "true"}, host_name: "localhost")

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "md5sum", "file", "dest", "checksum"])
  ensure
    FileUtils.rm_r(dest) if dest && Dir.exists?(dest)
  end

  it "serializes the check-mode skip as skipped, msg, changed (real carries no failed key there)" do
    src = unique_tmp("fetch-order3-src-txt")
    File.write(src, "check mode\n")

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => unique_tmp("fetch-order3-dest"), "flat" => "true", "_ansible_check_mode" => "true"}, host_name: "localhost")
    result.as_h.keys.must_equal(["skipped", "msg", "changed"])
  end
end

describe "wait_for plugin result key order" do
  it "serializes a path wait as state, port, search_regex, match_groups, match_groupdict, path, elapsed, then the stat block (wire: no changed)" do
    path = PluginSpecHelper.tmp_path("wait-for-order.txt")
    File.write(path, "here\n")

    result = PluginSpecHelper.run("wait_for", {"path" => path})
    result.as_h.keys.must_equal([
      "state", "port", "search_regex", "match_groups", "match_groupdict",
      "path", "elapsed", "uid", "gid", "owner", "group", "mode", "size",
    ])
  end

  it "serializes a timeout-only wait with path null and no stat block (wire: no changed)" do
    result = PluginSpecHelper.run("wait_for", {"timeout" => "1"})
    result.as_h.keys.must_equal([
      "state", "port", "search_regex", "match_groups", "match_groupdict",
      "path", "elapsed",
    ])
  end

  it "serializes the check-mode skip as skipped, msg (wire: no changed)" do
    result = PluginSpecHelper.run("wait_for", {"timeout" => "1", "_ansible_check_mode" => "true"})
    result.as_h.keys.must_equal(["skipped", "msg"])
  end

  it "registers a path wait ending failed, changed after the stat block" do
    path = PluginSpecHelper.tmp_path("wait-for-order-reg.txt")
    File.write(path, "here\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: wait for it
            ansible.builtin.wait_for:
              path: #{path}
              timeout: 1
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal([
      "state", "port", "search_regex", "match_groups", "match_groupdict",
      "path", "elapsed", "uid", "gid", "owner", "group", "mode", "size",
      "failed", "changed",
    ])
  end

  it "registers the check-mode skip as skipped, msg, failed, changed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: wait for it in check mode
            ansible.builtin.wait_for:
              timeout: 1
            check_mode: true
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["skipped", "msg", "failed", "changed"])
  end
end

describe "unarchive plugin result key order" do
  it "serializes an extract as handler, dest, src, changed, then the stat block (extract_results absent, files empty)" do
    work = unique_tmp("unarchive-order")
    Dir.mkdir_p(work)
    src_dir = File.join(work, "srcdir")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "a.txt"), "one\n")
    archive = File.join(work, "pack.tgz")
    Process.run("tar", ["czf", archive, "-C", src_dir, "."], output: Process::Redirect::Close, error: Process::Redirect::Close)
    dest = File.join(work, "unpack")
    Dir.mkdir_p(dest)

    result = PluginSpecHelper.run("unarchive", {"src" => archive, "dest" => dest})
    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "handler", "dest", "src", "changed", "files",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm_r(work) if work && Dir.exists?(work)
  end

  it "serializes the already-extracted rerun in the same order with changed false" do
    work = unique_tmp("unarchive-order2")
    Dir.mkdir_p(work)
    src_dir = File.join(work, "srcdir")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "a.txt"), "one\n")
    archive = File.join(work, "pack.tgz")
    Process.run("tar", ["czf", archive, "-C", src_dir, "."], output: Process::Redirect::Close, error: Process::Redirect::Close)
    dest = File.join(work, "unpack")
    Dir.mkdir_p(dest)

    PluginSpecHelper.run("unarchive", {"src" => archive, "dest" => dest})
    result = PluginSpecHelper.run("unarchive", {"src" => archive, "dest" => dest})
    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "handler", "dest", "src", "changed", "files",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm_r(work) if work && Dir.exists?(work)
  end
end

describe "archive plugin result key order" do
  it "serializes a create as archived, dest, dest_state, changed, arcroot, missing, expanded_paths, then the stat block" do
    work = unique_tmp("archive-order")
    Dir.mkdir_p(File.join(work, "srcdir"))
    File.write(File.join(work, "srcdir", "a.txt"), "one\n")
    dest = File.join(work, "made.tar.gz")

    result = PluginSpecHelper.run("archive", {"path" => File.join(work, "srcdir"), "dest" => dest, "format" => "gz"})
    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "archived", "dest", "dest_state", "changed", "arcroot", "missing", "expanded_paths",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm_r(work) if work && Dir.exists?(work)
  end

  it "serializes the already-archived rerun in the same order with changed false" do
    work = unique_tmp("archive-order2")
    Dir.mkdir_p(File.join(work, "srcdir"))
    File.write(File.join(work, "srcdir", "a.txt"), "one\n")
    dest = File.join(work, "made.tar.gz")

    PluginSpecHelper.run("archive", {"path" => File.join(work, "srcdir"), "dest" => dest, "format" => "gz"})
    result = PluginSpecHelper.run("archive", {"path" => File.join(work, "srcdir"), "dest" => dest, "format" => "gz"})
    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "archived", "dest", "dest_state", "changed", "arcroot", "missing", "expanded_paths",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm_r(work) if work && Dir.exists?(work)
  end
end

# A tiny local HTTP server for the uri order specs - ephemeral port, so
# parallel workers never collide.
URI_ORDER_SERVER = HTTP::Server.new do |context|
  context.response.status_code = 200
  context.response.headers["Content-Type"] = "text/plain"
  context.response.print("uri order body")
end

URI_ORDER_ADDRESS = URI_ORDER_SERVER.bind_unused_port
spawn do
  URI_ORDER_SERVER.listen
end

describe "uri plugin result key order" do
  it "serializes a GET as redirected, url, status, response headers, msg, elapsed, changed" do
    result = PluginSpecHelper.run("uri", {"url" => "http://#{URI_ORDER_ADDRESS}/text"})
    result["changed"].as_bool.must_equal(false)
    keys = result.as_h.keys
    keys.first(3).must_equal(["redirected", "url", "status"])
    # The header block is server-dependent; only pin the fixed tail and
    # that content_type sits in the header block (before msg).
    keys[keys.size - 3, 3].must_equal(["msg", "elapsed", "changed"])
    ct_index = keys.index("content_type")
    msg_index = keys.index("msg")
    (ct_index && msg_index && ct_index < msg_index).must_equal(true)
  end

  it "serializes a return_content GET with content leading" do
    result = PluginSpecHelper.run("uri", {"url" => "http://#{URI_ORDER_ADDRESS}/text", "return_content" => "true"})
    result["content"].as_s.must_equal("uri order body")
    keys = result.as_h.keys
    keys.first.must_equal("content")
    keys[keys.size - 3, 3].must_equal(["msg", "elapsed", "changed"])
  end

  it "serializes the check-mode skip as skipped, msg, changed" do
    result = PluginSpecHelper.run("uri", {"url" => "http://#{URI_ORDER_ADDRESS}/text", "_ansible_check_mode" => "true"})
    result.as_h.keys.must_equal(["skipped", "msg", "changed"])
  end
end

describe "debug registered-result key order" do
  it "registers a msg debug as msg, failed, changed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: msg debug
            ansible.builtin.debug:
              msg: "order probe"
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["msg", "failed", "changed"])
  end

  it "registers a var debug with the var name leading (real: varname, failed, changed)" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          krikri_order_probe_var: probe-value
        tasks:
          - name: var debug
            ansible.builtin.debug:
              var: krikri_order_probe_var
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["krikri_order_probe_var", "failed", "changed"])
  end
end

describe "set_fact registered-result key order" do
  it "registers as ansible_facts, failed, changed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: set it
            ansible.builtin.set_fact:
              krikri_order_fact: "1"
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["ansible_facts", "failed", "changed"])
  end
end

describe "assert registered-result key order" do
  it "registers a passing assert as changed, msg, failed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: assert
            ansible.builtin.assert:
              that: "1 == 1"
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
    keys.must_equal(["changed", "msg", "failed"])
  end
end

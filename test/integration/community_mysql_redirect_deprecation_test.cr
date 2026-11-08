require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# ansible-core 2.19.11's console output and registered-result shape
# for the community.mysql -> ansible.mysql collection-redirect
# deprecation (community.mysql 5.0.2's meta/runtime.yml plugin_routing,
# live-verified against ansible-playbook with
# `env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN
# -u ANSIBLE_CACHE_PLUGIN_CONNECTION`, tmp paths masked):
#
#   [WARNING]: Deprecation warnings can be disabled by setting
#   `deprecation_warnings=False` in ansible.cfg.
#   [DEPRECATION WARNING]: community.mysql.mysql_info has been
#   deprecated. Use ansible.mysql.mysql_info instead. This feature will
#   be removed from collection 'community.mysql' version 6.0.0.
#   Origin: /abs/play.yml:6:7
#
#   4   tasks:
#   5     - name: failing info
#   6       community.mysql.mysql_info:
#           ^ column 7
#
# - the trailer prints ONCE per run, before the first deprecation line;
# - each warning carries an Origin block (issue #973). An as-written
#   FQCN keeps the YAML tag on the module-name string, so real prints the
#   positioned block above at the module KEY's line/column, making every
#   task occurrence distinct; a bare spelling rebuilds the name by
#   joining the collection onto it, which drops that tag, so real prints
#   `Origin: <unknown>` with the resolved FQCN as its whole excerpt and
#   the block then dedups onto the run's first one;
# - one [DEPRECATION WARNING] block per DISTINCT formatted message per
#   run (Ansible's Display dedups on the whole message, Origin included)
#   - two bare mysql_info tasks print one block, two FQCN ones print two;
# - the lines print even for a `when: false`-skipped task (module
#   resolution happens at task load, before conditionals) and under
#   --list-tasks, and land before the PLAY banner;
# - every task result the module actually PRODUCED carries the
#   `deprecations` entry (via register: r.deprecations), a skipped task's
#   result carries none, and the entry's msg has NO removal tail (only
#   the console line does):
#     {"msg": "community.mysql.mysql_info has been deprecated. Use
#      ansible.mysql.mysql_info instead.", "collection_name":
#      "community.mysql", "version": "6.0.0", "deprecator":
#      {"resolved_name": "community.mysql", "type": null}}
# - the redirected TARGET spelling (ansible.mysql.*) does not warn.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private TRAILER_LINE = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."

private def deprecation_line(module_name : String) : String
  "[DEPRECATION WARNING]: community.mysql.#{module_name} has been deprecated. " \
  "Use ansible.mysql.#{module_name} instead. " \
  "This feature will be removed from collection 'community.mysql' version 6.0.0."
end

private PLAY_HEADER = [
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
]

# `tasks` are task lines already indented for the play's `tasks:` list.
# `collections` mirrors the play-level `collections:` keyword - real's
# loader searches the listed collections for bare (non-FQCN) module
# names and refuses the whole play when a bare unsupported name can't
# be qualified without it, so the bare-spelling tests below name their
# collection the same way real needs (krikri's own bare-name warning
# path cannot depend on it: MODULE_SEARCH_COLLECTIONS is global).
private def run_play(tasks : Array(String), collections : Array(String) = [] of String) : {Bool, String}
  success, output, _path = run_play_file(tasks, collections)
  {success, output}
end

# Same, plus the generated playbook's path: the positioned Origin blocks
# quote it, so the assertions that pin an exact line/column need it.
private def run_play_file(tasks : Array(String), collections : Array(String) = [] of String) : {Bool, String, String}
  playbook = File.tempname("mysql-redirect-deprecation", ".yml")
  body = PLAY_HEADER.dup
  body << "  collections: [#{collections.join(", ")}]" unless collections.empty?
  body << "  tasks:"
  body.concat(tasks)
  File.write(playbook, body.join("\n") + "\n")
  output = IO::Memory.new
  # One real pipe for both streams (2>&1 in the shell): Process.run with
  # the same IO for output and error copies them through two pipes on
  # separate fibers, so the relative order of the two streams - which the
  # banner-ordering assertion below depends on - flips under load.
  status = Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY, "-i", INVENTORY, playbook], output: output, input: IO::Memory.new)
  {status.success?, output.to_s, File.expand_path(playbook)}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# A guaranteed-failing read-only mysql task (nothing listens on the
# port): Ansible's own result for it carries the deprecations entry, so
# failure vs success is irrelevant to the assertions - only that the
# task executed rather than skipped.
private FAILING_MYSQL_INFO = [
  "    - name: failing info",
  "      community.mysql.mysql_info:",
  "        filter: \"*\"",
  "        login_host: 127.0.0.1",
  "        login_port: 33399",
  "      ignore_errors: true",
  "      register: r",
]

describe "community.mysql redirect deprecation" do
  it "prints the trailer once and one deprecation block per task occurrence, before the play banner" do
    success, output = run_play(FAILING_MYSQL_INFO + [
      "    - name: second use",
      "      community.mysql.mysql_info:",
      "        filter: \"*\"",
      "        login_host: 127.0.0.1",
      "        login_port: 33399",
      "      ignore_errors: true",
      "    - name: other module",
      "      community.mysql.mysql_query:",
      "        query: \"SELECT 1\"",
      "        login_host: 127.0.0.1",
      "        login_port: 33399",
      "      ignore_errors: true",
    ])
    success.must_equal(true, output)
    output.scan(TRAILER_LINE).size.must_equal(1)
    # FQCN spellings position their Origin block at the module key, which
    # makes each occurrence's message distinct (2.21.6) - so the two
    # mysql_info tasks print two blocks, mysql_query one.
    output.scan(deprecation_line("mysql_info")).size.must_equal(2)
    output.scan(deprecation_line("mysql_query")).size.must_equal(1)
    # Both stderr lines land before the play banner, like Ansible's
    # task-load-time emission.
    trailer_idx = output.index!(TRAILER_LINE)
    play_idx = output.index!("PLAY [localhost]")
    (trailer_idx < play_idx).must_equal(true, output)
  end

  it "attributes a bare spelling's warning to the position-less Origin block, once per run" do
    # net2grid.mysql-deploy (issue #973) spells mysql_db bare: real
    # resolves community.mysql.mysql_db from the builtin-runtime's
    # redirect, and that rebuilt name carries no YAML origin tag, so the
    # warning gets `Origin: <unknown>` with the FQCN as its whole excerpt.
    success, output = run_play([
      "    - name: bare one",
      "      mysql_db:",
      "        name: one",
      "        state: present",
      "      when: false",
      "    - name: bare two",
      "      mysql_db:",
      "        name: two",
      "        state: present",
      "      when: false",
    ], collections: ["community.mysql"])
    success.must_equal(true, output)
    output.includes?(
      "#{deprecation_line("mysql_db")}\nOrigin: <unknown>\n\ncommunity.mysql.mysql_db\n\n").must_equal(true, output)
    # Being position-less, the second occurrence's block matches the first
    # verbatim, so Ansible's display-time dedupe drops it.
    output.scan(deprecation_line("mysql_db")).size.must_equal(1)
    output.scan("Origin: <unknown>").size.must_equal(1)
  end

  it "attributes each FQCN spelling's warning to the module key's own position" do
    success, output, path = run_play_file([
      "    - name: fqcn one",
      "      community.mysql.mysql_db:",
      "        name: one",
      "        state: present",
      "      when: false",
      "    - name: fqcn two",
      "      community.mysql.mysql_db:",
      "        name: two",
      "        state: present",
      "      when: false",
    ])
    success.must_equal(true, output)
    # The as-written FQCN keeps its YAML tag, so real positions the block
    # at the module key (column 7 here) - and the positions differ, making
    # each occurrence its own message, which the dedupe then keeps.
    output.includes?(
      "#{deprecation_line("mysql_db")}\nOrigin: #{path}:6:7\n\n" \
      "4   tasks:\n5     - name: fqcn one\n6       community.mysql.mysql_db:\n        ^ column 7\n\n").must_equal(true, output)
    output.includes?(
      "#{deprecation_line("mysql_db")}\nOrigin: #{path}:11:7\n\n" \
      " 9       when: false\n10     - name: fqcn two\n11       community.mysql.mysql_db:\n         ^ column 7\n\n").must_equal(true, output)
    output.scan(deprecation_line("mysql_db")).size.must_equal(2)
  end

  it "does not warn for the redirected target spelling" do
    success, output = run_play([
      "    - name: target spelling",
      "      ansible.mysql.mysql_info:",
      "        filter: \"*\"",
      "        login_host: 127.0.0.1",
      "        login_port: 33399",
      "      ignore_errors: true",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(false)
    output.includes?("[DEPRECATION WARNING]").must_equal(false)
  end

  it "warns for the bare short-name spelling" do
    success, output = run_play([
      "    - name: bare name",
      "      mysql_info:",
      "        filter: \"*\"",
      "        login_host: 127.0.0.1",
      "        login_port: 33399",
      "      ignore_errors: true",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    output.includes?(deprecation_line("mysql_info")).must_equal(true, output)
  end

  it "warns on the console for a when-false skipped task" do
    success, output = run_play([
      "    - name: skipped info",
      "      community.mysql.mysql_info:",
      "        filter: \"*\"",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    output.includes?(deprecation_line("mysql_info")).must_equal(true, output)
    output.includes?("skipping: [localhost]").must_equal(true)
  end

  it "warns for tasks parsed before a later task's load-time refusal aborts the run" do
    # hakamine.c6-zabbix (issue 863): the role's tasks/main.yml uses
    # mysql_db a few tasks ahead of a removed bare `include:`. Real
    # resolves each task's module AS it loads the list, so the mysql_db
    # deprecation (and the once-per-run hint) print before the include
    # tombstone aborts the run - emitting only after the whole list
    # parsed lost every warning that preceded the aborting task.
    success, output = run_play([
      "    - name: db",
      "      community.mysql.mysql_db:",
      "        name: zabbix",
      "        state: present",
      "    - name: legacy include",
      "      include: tasks/foo.yml",
    ])
    success.must_equal(false, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    output.includes?(deprecation_line("mysql_db")).must_equal(true, output)
    output.includes?("[ERROR]: The 'ansible.builtin.include' action plugin has been removed.").must_equal(true, output)
    # The deprecation line lands before the refusal, matching Ansible's
    # per-task load order.
    deprecation_idx = output.index!(deprecation_line("mysql_db"))
    error_idx = output.index!("[ERROR]: The 'ansible.builtin.include'")
    (deprecation_idx < error_idx).must_equal(true, output)
  end

  it "attaches the deprecations entry to an executed result but not a skipped one" do
    success, output = run_play([
      "    - name: skipped info",
      "      community.mysql.mysql_info:",
      "        filter: \"*\"",
      "      when: false",
      "      register: skipped_r",
    ] + FAILING_MYSQL_INFO + [
      "    - name: show",
      "      ansible.builtin.debug:",
      "        msg: \"skipped={{ skipped_r.deprecations | default('NONE') }} executed={{ r.deprecations | to_json }}\"",
    ])
    success.must_equal(true, output)
    # The skipped result carries no deprecations entry...
    output.includes?("skipped=NONE").must_equal(true, output)
    # ...and the executed one carries exactly Ansible's entry shape.
    output.includes?("community.mysql.mysql_info has been deprecated. Use ansible.mysql.mysql_info instead.").must_equal(true, output)
    output.includes?("\\\"collection_name\\\": \\\"community.mysql\\\"").must_equal(true, output)
    output.includes?("\\\"version\\\": \\\"6.0.0\\\"").must_equal(true, output)
    output.includes?("\\\"deprecator\\\": {\\\"resolved_name\\\": \\\"community.mysql\\\", \\\"type\\\": null}").must_equal(true, output)
    # Only ONE entry even though the module appeared twice across tasks
    # (the console [DEPRECATION WARNING] line above carries the same msg
    # text, so match the dump-escaped form here).
    output.scan("\\\"msg\\\": \\\"community.mysql.mysql_info has been deprecated. Use ansible.mysql.mysql_info instead.\\\"").size.must_equal(1)
  end
end

# The unsupported end of the same redirect (see the header above):
# mysql_replication and mysql_role are NOT krikri-supported modules (the
# coverage bar), but real prints their task-load-time [DEPRECATION
# WARNING] exactly like the supported modules' ones - the
# hoplacloud.wordpress round diverged on the missing mysql_replication
# line (github issue 246). So the table covers them anyway, and these
# mirror proxmox_kvm_redirect_deprecation_test.cr's unsupported-module
# shape: every task when:-gated (an unguarded one would fail the run
# through reachable_unavailable_modules) and the deprecations result
# entry asserted directly against the table helpers rather than through
# a register: (the module never executes, so no result is produced to
# attach an entry to).
describe "community.mysql unsupported-module redirect deprecation" do
  it "warns at task-load time for when-skipped mysql_replication and mysql_role tasks" do
    success, output = run_play([
      "    - name: replication probe",
      "      community.mysql.mysql_replication:",
      "        mode: getprimary",
      "      when: false",
      "    - name: role probe",
      "      community.mysql.mysql_role:",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    output.includes?(deprecation_line("mysql_replication")).must_equal(true, output)
    output.includes?(deprecation_line("mysql_role")).must_equal(true, output)
    # The stderr lines land before the play banner, like Ansible's
    # task-load-time emission.
    trailer_idx = output.index!(TRAILER_LINE)
    play_idx = output.index!("PLAY [localhost]")
    (trailer_idx < play_idx).must_equal(true, output)
  end

  it "warns with the resolved community.mysql FQCN for the bare mysql_replication spelling" do
    # The bare unsupported spelling stays bare in task.module_name
    # (resolve_module_name comes up empty), so this exercises
    # MODULE_SEARCH_COLLECTIONS' qualification in
    # redirect_deprecation_lookup.
    success, output = run_play([
      "    - name: bare replication",
      "      mysql_replication:",
      "        mode: getprimary",
      "      when: false",
    ], collections: ["community.mysql"])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    # The line echoes the RESOLVED community.mysql FQCN, never the
    # as-written bare spelling.
    output.includes?(deprecation_line("mysql_replication")).must_equal(true, output)
  end

  it "carries the redirect msg, collection and removal version in the direct table lookups" do
    %w[mysql_replication mysql_role].each do |module_name|
      Krikri::PlaybookParser.redirect_deprecation_text("community.mysql.#{module_name}").must_equal(
        "community.mysql.#{module_name} has been deprecated. " \
        "Use ansible.mysql.#{module_name} instead. " \
        "This feature will be removed from collection 'community.mysql' version 6.0.0.")
      # The bare spelling must resolve to the same entry through
      # MODULE_SEARCH_COLLECTIONS, despite the module being
      # unimplemented.
      Krikri::PlaybookParser.redirect_deprecation_text(module_name).must_equal(
        Krikri::PlaybookParser.redirect_deprecation_text("community.mysql.#{module_name}"))
      entry = Krikri::PlaybookParser.redirect_deprecation_result_entry("community.mysql.#{module_name}")
      flunk("no deprecations result entry for #{module_name}") unless entry
      entry = entry.not_nil!
      # The msg carries NO removal tail; only the console line does.
      entry["msg"].as_s.must_equal(
        "community.mysql.#{module_name} has been deprecated. " \
        "Use ansible.mysql.#{module_name} instead.")
      entry["collection_name"].as_s.must_equal("community.mysql")
      entry["version"].as_s.must_equal("6.0.0")
      entry["deprecator"]["resolved_name"].as_s.must_equal("community.mysql")
      entry["deprecator"]["type"].as_s?.must_equal(nil)
    end
  end
end

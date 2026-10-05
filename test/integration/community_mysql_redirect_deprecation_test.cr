require "../minitest_helper"

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
#
# - the trailer prints ONCE per run, before the first deprecation line;
# - one [DEPRECATION WARNING] line per DISTINCT module per run (Ansible's
#   Display dedups on the message) - two mysql_info tasks print one line;
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
private def run_play(tasks : Array(String)) : {Bool, String}
  playbook = File.tempname("mysql-redirect-deprecation", ".yml")
  body = PLAY_HEADER.dup
  body << "  tasks:"
  body.concat(tasks)
  File.write(playbook, body.join("\n") + "\n")
  output = IO::Memory.new
  # One real pipe for both streams (2>&1 in the shell): Process.run with
  # the same IO for output and error copies them through two pipes on
  # separate fibers, so the relative order of the two streams - which the
  # banner-ordering assertion below depends on - flips under load.
  status = Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY, "-i", INVENTORY, playbook], output: output, input: IO::Memory.new)
  {status.success?, output.to_s}
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
  it "prints the trailer once and one deprecation line per distinct module, before the play banner" do
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
    output.scan(deprecation_line("mysql_info")).size.must_equal(1)
    output.scan(deprecation_line("mysql_query")).size.must_equal(1)
    # Both stderr lines land before the play banner, like Ansible's
    # task-load-time emission.
    trailer_idx = output.index!(TRAILER_LINE)
    play_idx = output.index!("PLAY [localhost]")
    (trailer_idx < play_idx).must_equal(true, output)
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

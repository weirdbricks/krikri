require "../minitest_helper"
require "file_utils"

# ansible.builtin.assert's list-valued fail_msg/msg/success_msg (spec
# type str_or_list_of_str) output parity (issue #1184,
# live-verified byte-for-byte against ansible-core 2.21.6 with
# linux-system-roles.mssql's own EULA assert):
#
# - Ansible's assert action assigns `result['msg'] = fail_msg` verbatim,
#   so a list-valued fail_msg fails with the REAL list in the fatal dump
#   ("msg": [ ... ], 4-space pretty indent) and the [ERROR] chain reprs
#   it as Python would ("['a', 'b']"). The strings-only param wire used
#   to comma-join the list into one string, so every line of a multi-line
#   fail_msg fused ("a,b") in both places.
# - A templated whole value (`fail_msg: "{{ msg_list }}"`) and a list
#   carrying `{{ }}` template leaves keep the same native list shape,
#   with each leaf rendered as its own string (Ansible templates list
#   items element-by-element).
# - success_msg list on a PASSING assert dumps the real list the same
#   way.
# - A list with non-string members fails Ansible's str_or_list_of_str
#   callable with the wrapped TypeError before the assert action runs.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(playbook : String, files : Hash(String, String)) : {Process::Status, String}
  dir = File.tempname("assert-list-msg", ".d")
  Dir.mkdir(dir)
  files.each do |path, content|
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, playbook)], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# *fail_msg_yaml* is the YAML text under `fail_msg:` at its own 10-space
# indentation (list items or one scalar line).
private def failing_assert_play(fail_msg_yaml : String) : String
  <<-YAML

    - hosts: all
      gather_facts: false
      vars:
        flag_var: false
        msg_list:
          - "templated one"
          - "templated two"
        leaf_val: "LEAF"
      tasks:
        - name: failing assert
          ansible.builtin.assert:
            that: ["flag_var | bool"]
            fail_msg:
    #{fail_msg_yaml}
    YAML
end

describe "assert list fail_msg output parity" do
  it "keeps a literal list fail_msg a real list in the dump and reprs it in the chain" do
    status, output = run_playbook("play.yml", {
      "play.yml" => failing_assert_play(%(          - "line one"\n          - "line two")),
    })

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Action failed: ['line one', 'line two']")
    output.must_include(<<-JSON)
      fatal: [localhost]: FAILED! => {
          "assertion": "flag_var | bool",
          "changed": false,
          "evaluated_to": false,
          "msg": [
              "line one",
              "line two"
          ]
      }
      JSON
    output.wont_include("line one,line two")
  end

  it "keeps a templated whole-value fail_msg a real list" do
    status, output = run_playbook("play.yml", {
      "play.yml" => failing_assert_play(%(          "{{ msg_list }}")),
    })

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Action failed: ['templated one', 'templated two']")
    output.must_include(%(    "msg": [\n        "templated one",\n        "templated two"\n    ]))
    output.wont_include(%(msg": "[\\"templated one\\"))
  end

  it "renders a list fail_msg's template leaves per element and keeps the list" do
    status, output = run_playbook("play.yml", {
      "play.yml" => failing_assert_play(%(          - "leaf is {{ leaf_val }} here"\n          - "static")),
    })

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Action failed: ['leaf is LEAF here', 'static']")
    output.must_include(%(    "msg": [\n        "leaf is LEAF here",\n        "static"\n    ]))
    output.wont_include("leaf is LEAF here,static")
  end

  it "keeps a list success_msg a real list on the passing assert's ok dump" do
    status, output = run_playbook("play.yml", {
      "play.yml" => <<-YAML,
      - hosts: all
        gather_facts: false
        tasks:
          - name: passing assert
            ansible.builtin.assert:
              that: ["1 == 1"]
              success_msg:
                - "all good one"
                - "all good two"
      YAML
    })

    status.exit_code.must_equal(0)
    output.must_include(<<-JSON)
      ok: [localhost] => {
          "changed": false,
          "msg": [
              "all good one",
              "all good two"
          ]
      }
      JSON
    output.wont_include("all good one,all good two")
  end

  it "fails a non-string-member list fail_msg with str_or_list_of_str's wrapped TypeError" do
    status, output = run_playbook("play.yml", {
      "play.yml" => failing_assert_play(%(          - 1\n          - "a")),
    })

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: argument 'fail_msg' is of type list and we were unable to convert to str_or_list_of_str: a string or list of strings is required")
    output.must_include(%("msg": "argument 'fail_msg' is of type list and we were unable to convert to str_or_list_of_str: a string or list of strings is required"))
    output.wont_include(%("assertion"))
  end
end

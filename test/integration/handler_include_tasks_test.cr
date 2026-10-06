require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against a real playbook (a real notified
# handler using include_tasks:, not --check mode), since this bug is
# specifically about TaskExecutor#execute_handler_plugin_once, a private
# method not reachable from a unit spec without constructing a whole
# TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a handler using include_tasks:" do
  it "runs the included file's tasks instead of crashing the whole run" do
    # Real crash found benchmarking Anthony25.unbound (round828): its
    # "restart unbound" handler is `include_tasks: tasks/restart_unbound.yml`
    # - a Ansible pattern (a handler can include a task file exactly
    # like a regular task can). #execute_handler_plugin_once only ever
    # special-cased ansible.builtin.reboot before falling through to
    # normal plugin dispatch - a handler's include_tasks: (the synthetic
    # "_include_tasks" pseudo-module, never backed by a real plugin
    # binary) hit that same fallthrough and crashed the ENTIRE run with
    # an unhandled exception ("Plugin binary not found: _include_tasks")
    # the moment the handler was notified, instead of running the
    # included file's tasks the way the regular-task include_tasks: path
    # (execute_include_tasks) already does.
    dir = File.tempname("handler-include-tasks")
    Dir.mkdir_p(File.join(dir, "tasks"))

    File.write(File.join(dir, "site.yml"), <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: restart thing
        handlers:
          - name: restart thing
            ansible.builtin.include_tasks: tasks/inner.yml
      YAML

    File.write(File.join(dir, "tasks", "inner.yml"), <<-YAML)
      - name: inner task
        ansible.builtin.debug:
          msg: included task ran
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "site.yml")], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("included task ran")
    output.to_s.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

# The DISPLAY shape of a handler flush that includes task files. Every
# expected output below is the verbatim ansible-core 2.19.11 output of
# the same fixture: the include statement's own result line is
# `included: <path> for <host>` (never an `ok:` line), every task the
# include pulls in - directly or through a further nested include -
# banners as "RUNNING HANDLER [...]", and the recap counts each include
# as one `ok`.
describe "handler include_tasks display" do
  private def run_fixture(dir : String)
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "site.yml"], output: output, error: output, chdir: dir)
    {status, output.to_s.gsub(dir, "FIXDIR")}
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "banners everything RUNNING HANDLER with included: lines, byte for byte" do
    dir = File.tempname("handler-inc-display")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "tinc1.yml"), <<-YAML)
      - name: h task one
        debug: {msg: one}
      - name: h task two
        debug: {msg: two}
      - debug: {msg: unnamed h}
      - name: nested include
        include_tasks: inc4.yml
      YAML
    File.write(File.join(dir, "inc4.yml"), "- name: deep task\n  debug: {msg: deep}\n")
    File.write(File.join(dir, "inc2.yml"), "- name: h from inc2\n  debug: {msg: two2}\n")
    File.write(File.join(dir, "inc3.yml"), "- name: h from inc3\n  debug: {msg: three}\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            command: /bin/true
            notify:
              - my handler
              - unnamed include handler
              - listened handler
        handlers:
          - name: my handler
            include_tasks: tinc1.yml
          - name: unnamed include handler
            include_tasks: inc2.yml
          - name: listened handler
            include_tasks: inc3.yml
            listen: [L1]
      YAML

    status, output = run_fixture(dir)
    status.success?.must_equal(true)
    output.must_equal(<<-OUT + "\n\n")

      PLAY [localhost] ***************************************************************

      TASK [trigger] *****************************************************************
      changed: [localhost]

      RUNNING HANDLER [my handler] ***************************************************
      included: FIXDIR/tinc1.yml for localhost

      RUNNING HANDLER [h task one] ***************************************************
      ok: [localhost] => {
          "msg": "one"
      }

      RUNNING HANDLER [h task two] ***************************************************
      ok: [localhost] => {
          "msg": "two"
      }

      RUNNING HANDLER [debug] ********************************************************
      ok: [localhost] => {
          "msg": "unnamed h"
      }

      RUNNING HANDLER [nested include] ***********************************************
      included: FIXDIR/inc4.yml for localhost

      RUNNING HANDLER [deep task] ****************************************************
      ok: [localhost] => {
          "msg": "deep"
      }

      RUNNING HANDLER [unnamed include handler] **************************************
      included: FIXDIR/inc2.yml for localhost

      RUNNING HANDLER [h from inc2] **************************************************
      ok: [localhost] => {
          "msg": "two2"
      }

      RUNNING HANDLER [listened handler] *********************************************
      included: FIXDIR/inc3.yml for localhost

      RUNNING HANDLER [h from inc3] **************************************************
      ok: [localhost] => {
          "msg": "three"
      }

      PLAY RECAP *********************************************************************
      localhost                  : ok=11   changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0#{"   "}
      OUT
  end

  it "prints every iteration's included line before the included tasks, byte for byte" do
    dir = File.tempname("handler-inc-loop")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inc2.yml"), "- name: h from inc2\n  debug: {msg: two2}\n")
    File.write(File.join(dir, "inc3.yml"), "- name: h from inc3\n  debug: {msg: three}\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            command: /bin/true
            notify:
              - looped include
        handlers:
          - name: looped include
            include_tasks: "{{ item }}"
            loop:
              - inc2.yml
              - inc3.yml
      YAML

    status, output = run_fixture(dir)
    status.success?.must_equal(true)
    output.must_equal(<<-OUT + "\n\n")

      PLAY [localhost] ***************************************************************

      TASK [trigger] *****************************************************************
      changed: [localhost]

      RUNNING HANDLER [looped include] ***********************************************
      included: FIXDIR/inc2.yml for localhost => (item=inc2.yml)
      included: FIXDIR/inc3.yml for localhost => (item=inc3.yml)

      RUNNING HANDLER [h from inc2] **************************************************
      ok: [localhost] => {
          "msg": "two2"
      }

      RUNNING HANDLER [h from inc3] **************************************************
      ok: [localhost] => {
          "msg": "three"
      }

      PLAY RECAP *********************************************************************
      localhost                  : ok=5    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0#{"   "}
      OUT
  end

  it "prints the included: line for a comment-only include file" do
    dir = File.tempname("handler-inc-empty")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "empty.yml"), "# just a comment\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            command: /bin/true
            notify: empty include
        handlers:
          - name: empty include
            include_tasks: empty.yml
      YAML

    status, output = run_fixture(dir)
    status.success?.must_equal(true)
    # Verbatim ansible-core 2.19.11: the include still happened (one ok),
    # it just had no tasks.
    output.must_equal(<<-OUT + "\n\n")

      PLAY [localhost] ***************************************************************

      TASK [trigger] *****************************************************************
      changed: [localhost]

      RUNNING HANDLER [empty include] ************************************************
      included: FIXDIR/empty.yml for localhost

      PLAY RECAP *********************************************************************
      localhost                  : ok=2    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0#{"   "}
      OUT
  end

  it "fails with real's missing-file fatal shape" do
    dir = File.tempname("handler-inc-missing")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            command: /bin/true
            notify: missing file handler
        handlers:
          - name: missing file handler
            include_tasks: nope.yml
      YAML

    status, output = run_fixture(dir)
    # ansible-core 2.19.11: rc=2, failed=1, the "[ERROR]: Could not find
    # or access ..." block plus the {"changed": false, "include": ...,
    # "reason": ...} fatal line - the same shape a regular task's
    # include_tasks: gets.
    status.exit_code.must_equal(2)
    output.must_include("RUNNING HANDLER [missing file handler]")
    output.must_include("Could not find or access 'FIXDIR/nope.yml' on the Ansible Controller")
    output.wont_include("Included tasks file not found")
    output.must_include("\"reason\": \"Could not find or access 'FIXDIR/nope.yml'")
    output.must_include("localhost                  : ok=1    changed=1    unreachable=0    failed=1")
  end

  it "fails with real's not-a-list fatal shape" do
    dir = File.tempname("handler-inc-notlist")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "notlist.yml"), "a: 1\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            command: /bin/true
            notify: bad include
        handlers:
          - name: bad include
            include_tasks: notlist.yml
      YAML

    status, output = run_fixture(dir)
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: included task files must contain a list of tasks")
    output.must_include("\"reason\": \"included task files must contain a list of tasks\"")
    output.must_include("localhost                  : ok=1    changed=1    unreachable=0    failed=1")
  end

  it "reaches an unnamed include_tasks handler via its listen: topic" do
    dir = File.tempname("handler-inc-listen")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inc5.yml"), "- name: cond task\n  debug: {msg: c}\n  when: false\n- name: a block in handler file\n  block:\n    - name: block child\n      debug: {msg: bc}\n    - debug: {msg: bunnamed}\n")
    File.write(File.join(dir, "vars.yml"), "incfile: inc5.yml\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars_files:
          - vars.yml
        tasks:
          - name: trigger
            command: /bin/true
            changed_when: true
            notify: via_listen
        handlers:
          - include_tasks: "{{ incfile }}"
            listen: via_listen
      YAML

    status, output = run_fixture(dir)
    status.success?.must_equal(true)
    # Verbatim ansible-core 2.19.11: the unnamed handler banners by its
    # action, the when:-false task inside skips under its own RUNNING
    # HANDLER banner, and the block's children list flat.
    output.must_equal(<<-OUT + "\n\n")

      PLAY [localhost] ***************************************************************

      TASK [trigger] *****************************************************************
      changed: [localhost]

      RUNNING HANDLER [include_tasks] ************************************************
      included: FIXDIR/inc5.yml for localhost

      RUNNING HANDLER [cond task] ****************************************************
      skipping: [localhost]

      RUNNING HANDLER [block child] **************************************************
      ok: [localhost] => {
          "msg": "bc"
      }

      RUNNING HANDLER [debug] ********************************************************
      ok: [localhost] => {
          "msg": "bunnamed"
      }

      PLAY RECAP *********************************************************************
      localhost                  : ok=4    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0#{"   "}
      OUT
  end
end

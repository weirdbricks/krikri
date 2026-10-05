require "../minitest_helper"

# Registered key ORDER of FAILED controller-side action results, live-verified
# against ansible-core 2.19.11 per action with `{{ r | to_json }}` under
# `ignore_errors: true` (Ansible's registered dict keeps each action's own
# insertion order, and every failure carries `exception:
# "(traceback unavailable)"` - see Krikri::FAILED_KEY_ORDER_DEFAULT):
#
#   fail            - failed, msg, changed, exception
#   assert          - failed, evaluated_to, assertion, msg, changed, exception
#   copy/template   - failed, msg, exception, changed   (missing controller src)
#   unarchive       - failed, exception, msg, changed
#   add_host        - failed, msg, exception, changed
#   group_by        - failed, msg, changed, exception
#   set_fact        - failed, exception, msg, changed   (invalid variable name)
#   debug (args)    - failed, exception, msg, changed   (undefined var in msg:)

private BINARY    = File.expand_path("../../bin/krikri-playbook", __DIR__)
private INVENTORY = File.expand_path("../fixtures/inventory-explicit-localhost.ini", __DIR__)

# Runs a play whose only failing task registers `r`, and returns that
# registered result's keys in order.
private def failed_key_order(tasks : String) : Array(String)
  playbook = File.tempname("action-failure-key-order", ".yml")
  # Dedent the heredoc task block, then re-indent it under `tasks:` next to
  # the dump task (krikri's parser rejects mismatched sibling indentation).
  body = tasks.lines.map(&.chomp).reject(&.empty?)
  pad = body.min_of { |line| line.size - line.lstrip.size }
  File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
    #{body.map { |line| "        " + line[pad..] }.join("\n")}
            - name: dump
              ansible.builtin.copy:
                content: |-
                  {{ r | to_json }}
                dest: #{PluginSpecHelper.tmp_path("action-failure-order.json")}
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s)
  JSON.parse(File.read(PluginSpecHelper.tmp_path("action-failure-order.json"))).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "action-level failure registered key order" do
  it "registers fail with failed, msg, changed, exception" do
    failed_key_order(<<-T).must_equal(["failed", "msg", "changed", "exception"])
      - name: f
        ansible.builtin.fail: {msg: boom}
        ignore_errors: true
        register: r
    T
  end

  it "registers assert with its condition keys before msg" do
    failed_key_order(<<-T).must_equal(["failed", "evaluated_to", "assertion", "msg", "changed", "exception"])
      - name: a
        ansible.builtin.assert: {that: [false], fail_msg: nope}
        ignore_errors: true
        register: r
    T
  end

  it "registers copy's missing controller src with exception before changed" do
    failed_key_order(<<-T).must_equal(["failed", "msg", "exception", "changed"])
      - name: c
        ansible.builtin.copy: {src: /nonexistent-src-key-order, dest: /tmp/krikri-key-order-dst}
        ignore_errors: true
        register: r
    T
  end

  it "registers template's missing controller src with exception before changed" do
    failed_key_order(<<-T).must_equal(["failed", "msg", "exception", "changed"])
      - name: t
        ansible.builtin.template: {src: /nonexistent-tmpl.j2, dest: /tmp/krikri-key-order-out.txt}
        ignore_errors: true
        register: r
    T
  end

  it "registers unarchive's missing controller src with exception first" do
    failed_key_order(<<-T).must_equal(["failed", "exception", "msg", "changed"])
      - name: u
        ansible.builtin.unarchive: {src: /nonexistent-key-order.tgz, dest: /tmp/krikri-key-order-dir}
        ignore_errors: true
        register: r
    T
  end

  it "registers add_host's missing-name failure with exception before changed" do
    failed_key_order(<<-T).must_equal(["failed", "msg", "exception", "changed"])
      - name: h
        ansible.builtin.add_host: {}
        ignore_errors: true
        register: r
    T
  end

  it "registers group_by's missing-key failure in the plain fail_json order" do
    failed_key_order(<<-T).must_equal(["failed", "msg", "changed", "exception"])
      - name: g
        ansible.builtin.group_by: {}
        ignore_errors: true
        register: r
    T
  end

  it "registers set_fact's invalid variable name with exception first" do
    failed_key_order(<<-T).must_equal(["failed", "exception", "msg", "changed"])
      - name: s
        ansible.builtin.set_fact: {"bad name": 1}
        ignore_errors: true
        register: r
    T
  end

  it "registers a debug arg-finalization failure with changed backfilled" do
    failed_key_order(<<-T).must_equal(["failed", "exception", "msg", "changed"])
      - name: d
        ansible.builtin.debug: {msg: "{{ nope_undefined_key_order }}"}
        ignore_errors: true
        register: r
    T
  end
end

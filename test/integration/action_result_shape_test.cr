require "../minitest_helper"

# Registered-result shapes of controller-side actions, live-verified against
# ansible-core 2.19.11 by dumping `{{ r | to_json }}` from real and krikri
# runs and comparing the full console output (byte-identical for the raw
# failure/check-mode cases):
#
#   group_by - exactly {changed, add_group, parent_groups, failed}: ONE group
#              name (spaces become `-`, never split on commas), parents
#              defaults to ["all"]; changed is true only the first time.
#   raw      - {rc, stdout, stdout_lines, stderr, stderr_lines, changed,
#              failed} (no cmd/start/end/delta/msg - raw is aliased to the
#              shell plugin binary, whose command-style extras real's raw
#              never returns); a non-zero rc adds msg + exception; check
#              mode is the bare {skipped, failed, changed} executor skip.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a play whose registered `r` is copied through `{{ r | to_json }}`
# into a file (avoiding the display layer's escaping) and returns it parsed.
private def registered_dump(tasks : String) : JSON::Any
  dump = PluginSpecHelper.tmp_path("action-shape-dump-#{Random::Secure.hex(4)}.json")
  playbook = File.tempname("action-shape", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
    #{tasks.lines.map { |line| "    " + line }.join("\n")}
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: #{dump}
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump))
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "group_by result shape" do
  it "registers add_group with spaces as dashes and the default all parent" do
    result = registered_dump(<<-T)
      - ansible.builtin.group_by:
          key: krikri shape group one
        register: r
      T
    result.as_h.keys.must_equal(["changed", "add_group", "parent_groups", "failed"])
    result["add_group"].as_s.must_equal("krikri-shape-group-one")
    result["parent_groups"].as_a.map(&.as_s).must_equal(["all"])
    result["changed"].as_bool.must_equal(true)
  end

  it "keeps a comma in the key as part of one group name" do
    result = registered_dump(<<-T)
      - ansible.builtin.group_by:
          key: krikri_a,krikri_b
        register: r
      T
    result["add_group"].as_s.must_equal("krikri_a,krikri_b")
  end

  it "reports an explicit parents string as a one-element parent_groups" do
    result = registered_dump(<<-T)
      - ansible.builtin.group_by:
          key: krikri_child
          parents: krikri_parent
        register: r
      T
    result["parent_groups"].as_a.map(&.as_s).must_equal(["krikri_parent"])
  end
end

describe "raw result shape" do
  it "registers a success as rc, stdout, stdout_lines, stderr, stderr_lines, changed, failed" do
    result = registered_dump(<<-T)
      - ansible.builtin.raw: echo out; echo err >&2
        register: r
      T
    result.as_h.keys.must_equal(%w[rc stdout stdout_lines stderr stderr_lines changed failed])
    result["stdout"].as_s.strip.must_equal("out")
    result["changed"].as_bool.must_equal(true)
  end

  it "registers a non-zero rc with msg and exception after failed" do
    result = registered_dump(<<-T)
      - ansible.builtin.raw: exit 3
        register: r
        ignore_errors: true
      T
    result.as_h.keys.must_equal(%w[rc stdout stdout_lines stderr stderr_lines changed failed msg exception])
    result["rc"].as_i.must_equal(3)
    result["msg"].as_s.must_equal("non-zero return code")
  end

  it "skips under check mode with the bare skipped, failed, changed shape" do
    result = registered_dump(<<-T)
      - ansible.builtin.raw: echo hi
        register: r
        check_mode: true
      T
    result.as_h.keys.must_equal(%w[skipped failed changed])
    result["changed"].as_bool.must_equal(false)
  end
end

describe "add_host result shape" do
  it "registers changed, add_host, failed with only the task's own args as host_vars" do
    result = registered_dump(<<-T)
      - ansible.builtin.add_host:
          name: krikri-shape-host
          groups: krikri_shape_grp
          custom_var: hello
        register: r
      T
    result.as_h.keys.must_equal(%w[changed add_host failed])
    result["add_host"]["host_vars"].as_h.keys.must_equal(["custom_var"])
    result["add_host"]["groups"].as_a.map(&.as_s).must_equal(["krikri_shape_grp"])
  end
end

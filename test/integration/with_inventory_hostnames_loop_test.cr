require "../minitest_helper"
require "file_utils"

# Legacy `with_inventory_hostnames:` - the loop-keyword form of the
# inventory_hostnames lookup. TaskExecutor#resolve_loop_lookup evaluates
# the source as `query('inventory_hostnames', term, wantlist=True)` on
# the krikri-jinja engine, NEVER through the hand-rolled evaluator's own
# lookup dispatch that direct `{{ lookup('inventory_hostnames', ...) }}`
# text takes (see test/integration/inventory_hostnames_lookup_test.cr).
# The engine-side lookup was missing the inventory_hostnames arm, so
# every executed such loop failed with "lookup plugin
# (inventory_hostnames) not found", and a false block's skip degraded to
# a single bare skipping line instead of per-item lines.
#
# Expected shapes: an executed loop shows `ok: [host] => (item=<label>)`
# per matched inventory hostname (the task counts ONCE in the recap), and
# a block-false skip shows one `skipping: [host] => (item=...)` line per
# matched host (trailing space included) plus the trailing bare
# `skipping: [host]` line - the latter matches the real ansible-playbook
# output in issue #275.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private INVENTORY = <<-'INI'
  ungroupedhost ansible_connection=local

  [webservers]
  web1 ansible_connection=local
  web2 ansible_connection=local

  [dbservers]
  db1 ansible_connection=local
  INI

describe "with_inventory_hostnames loop" do
  def run_play(playbook : String) : String
    dir = File.tempname("withih-loop", ".d")
    Dir.mkdir(dir)
    inventory = File.join(dir, "inventory.ini")
    File.write(inventory, INVENTORY)
    pb = File.join(dir, "pb.yml")
    File.write(pb, playbook)

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, pb], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s
  ensure
    FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
  end

  it "loops a group's inventory hostnames with loop_var/label on the executed path" do
    output = run_play(<<-YAML)
      - name: repro
        hosts: web1
        gather_facts: false
        vars:
          grp: webservers
        tasks:
          - name: Run it
            debug:
              msg: "peer-{{ m }}"
            with_inventory_hostnames:
              - "{{ grp }}"
            loop_control:
              loop_var: m
              label: "peer-{{ m }}"
      YAML

    output.must_include("ok: [web1] => (item=peer-web1) => {")
    output.must_include("\"msg\": \"peer-web1\"")
    output.must_include("ok: [web1] => (item=peer-web2) => {")
    output.must_include("\"msg\": \"peer-web2\"")
    # Real counts the looped task once per host, not once per item.
    output.must_match(/web1\s*:\s*ok=1 .*skipped=0/)
    output.wont_include("lookup plugin (inventory_hostnames) not found")
  end

  it "prints per-item skipping lines on the false-block skip path" do
    output = run_play(<<-YAML)
      - name: repro
        hosts: web1
        gather_facts: false
        vars:
          grp: webservers
          ctl: no-such-controller
        tasks:
          - block:
              - name: Sign it
                debug:
                  msg: hi
                with_inventory_hostnames:
                  - "{{ grp }}"
                loop_control:
                  loop_var: m
                  label: "peer-{{ m }}"
                when: m in ansible_play_hosts
            when: inventory_hostname == ctl
      YAML

    lines = output.lines
    idx = lines.index! { |line| line.starts_with?("TASK [Sign it]") }
    idx.must_equal(lines.rindex { |line| line.starts_with?("TASK [Sign it]") })
    # The per-item lines render the loop_control.label and carry the
    # trailing space (empty -v dump slot), then the bare trailing line.
    lines[idx + 1].must_equal("skipping: [web1] => (item=peer-web1) ")
    lines[idx + 2].must_equal("skipping: [web1] => (item=peer-web2) ")
    lines[idx + 3].must_equal("skipping: [web1]")
    # The loop source must not push the whole task into the generic
    # rescue / collapse-to-one-line shape (skipped=1 for the TASK,
    # never a failed recap entry).
    output.must_match(/web1\s*:\s*ok=0 .*skipped=1/)
    output.wont_include("lookup plugin (inventory_hostnames) not found")
  end
end

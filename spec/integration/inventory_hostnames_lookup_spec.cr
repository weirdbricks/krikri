require "../spec_helper"
require "file_utils"

# lookup('inventory_hostnames', pattern) - real Ansible's own inventory
# lookup plugin, previously unimplemented (fell through to "undefined").
# The real plugin builds a throwaway InventoryManager purely from
# variables['groups'] and runs the standard host-pattern machinery over
# it, so this is implemented in the evaluator against the same `groups`
# magic var (no inventory plumbing needed - see
# ExpressionEvaluator#lookup_inventory_hostnames).
#
# Every expected value below was verified against the locally-installed
# ansible-core 2.19.4 running the identical playbook + inventory
# (differential run, 12 patterns: group name, wantlist, query(), union,
# exclusion, single index, INCLUSIVE range, glob, ungrouped, no-match,
# groups['ungrouped'] magic var, &-intersection) before being pinned
# here.
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

# {tag, pattern expression, expected rendered msg}
private CASES = [
  {"t01", "lookup('inventory_hostnames', 'webservers')", "web1,web2"},
  {"t02", "lookup('inventory_hostnames', 'webservers', wantlist=True)", "[\"web1\",\"web2\"]"},
  {"t03", "query('inventory_hostnames', 'all')", "[\"ungroupedhost\",\"web1\",\"web2\",\"db1\"]"},
  {"t04", "lookup('inventory_hostnames', 'webservers:dbservers')", "web1,web2,db1"},
  {"t05", "lookup('inventory_hostnames', 'all:!webservers')", "ungroupedhost,db1"},
  {"t06", "lookup('inventory_hostnames', 'webservers[0]')", "web1"},
  {"t07", "lookup('inventory_hostnames', 'webservers[0:1]')", "web1,web2"},
  {"t08", "lookup('inventory_hostnames', 'web*')", "web1,web2"},
  {"t09", "lookup('inventory_hostnames', 'ungrouped')", "ungroupedhost"},
  {"t10", "lookup('inventory_hostnames', 'nosuchgroup')", "[]"},
  {"t11", "groups['ungrouped']", "['ungroupedhost']"},
  {"t12", "lookup('inventory_hostnames', 'webservers:&db1')", "[]"},
]

describe "lookup('inventory_hostnames', ...)" do
  CASES.each do |tag, expr, expected|
    it "matches ansible-core 2.19.4 (#{tag}: #{expr})" do
      dir = File.tempname("ih-spec", ".d")
      Dir.mkdir(dir)
      inventory = File.join(dir, "inventory.ini")
      File.write(inventory, INVENTORY)
      playbook = File.join(dir, "pb.yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: pattern under test
              debug:
                msg: "TAG={{ #{expr} }}"
        YAML

      captured = IO::Memory.new
      Process.run(BINARY, ["-i", inventory, playbook], output: captured, error: captured)
      rendered = captured.to_s[/TAG=(.*)/, 1]
      rendered.should eq(expected)
    ensure
      FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
    end
  end
end

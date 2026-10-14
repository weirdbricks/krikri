require "../minitest_helper"
require "file_utils"

# lookup('inventory_hostnames', pattern) - Ansible's own inventory
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
# here. (t02/t03 re-pinned against ansible-core 2.19.11: list results embedded in
# mixed text print as Python repr `['web1', 'web2']`, not compact JSON.)
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

private def pattern_playbook(expr : String) : String
  <<-YAML
  - hosts: localhost
    gather_facts: false
    tasks:
      - name: pattern under test
        debug:
          msg: "TAG={{ #{expr} }}"
  YAML
end

# {tag, pattern expression, expected rendered msg} - held as a compile-time
# table because minitest's `it` compiles to a generated method, so the rows
# can't be registered from a runtime loop like crystal spec's closure-based
# `it` could (see test/unit/p2_parity_matrix_test.cr).
describe "lookup('inventory_hostnames', ...)" do
  {% begin %}
    {% cases = {
         "t01" => {"lookup('inventory_hostnames', 'webservers')", "web1,web2"},
         "t02" => {"lookup('inventory_hostnames', 'webservers', wantlist=True)", "['web1', 'web2']"},
         "t03" => {"query('inventory_hostnames', 'all')", "['ungroupedhost', 'web1', 'web2', 'db1']"},
         "t04" => {"lookup('inventory_hostnames', 'webservers:dbservers')", "web1,web2,db1"},
         "t05" => {"lookup('inventory_hostnames', 'all:!webservers')", "ungroupedhost,db1"},
         "t06" => {"lookup('inventory_hostnames', 'webservers[0]')", "web1"},
         "t07" => {"lookup('inventory_hostnames', 'webservers[0:1]')", "web1,web2"},
         "t08" => {"lookup('inventory_hostnames', 'web*')", "web1,web2"},
         "t09" => {"lookup('inventory_hostnames', 'ungrouped')", "ungroupedhost"},
         "t10" => {"lookup('inventory_hostnames', 'nosuchgroup')", "[]"},
         "t11" => {"groups['ungrouped']", "['ungroupedhost']"},
         "t12" => {"lookup('inventory_hostnames', 'webservers:&db1')", "[]"},
       } %}
    {% for tag, row in cases %}
      {% cname = "matches ansible-core 2.19.4 (" + tag.id.stringify + ": " + row[0].id.stringify + ")" %}
      it {{ cname }} do
        expr = {{ row[0] }}
        expected = {{ row[1] }}
        dir = File.tempname("ih-spec", ".d")
        Dir.mkdir(dir)
        inventory = File.join(dir, "inventory.ini")
        File.write(inventory, INVENTORY)
        playbook = File.join(dir, "pb.yml")
        File.write(playbook, pattern_playbook(expr))

        captured = IO::Memory.new
        Process.run(BINARY, ["-i", inventory, playbook], output: captured, error: captured)
        rendered = captured.to_s[/TAG=(.*)"/, 1]
        rendered.must_equal(expected)
      ensure
        FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
      end
    {% end %}
  {% end %}
end

# Real InventoryManager._enumerate_matches prints a warning on stderr for
# each unique pattern term that matched neither group nor host names
# (verified against ansible-core 2.19 for both lookup() and query(): the
# line appears just before the task's ok: output). Out-of-range subscripts
# on matched hosts and ! / & terms stay silent - the former errors inside
# the lookup instead, the latter match nothing by design.
private def warning_line(pattern : String) : String
  "[WARNING]: Could not match supplied host pattern, ignoring: #{pattern}"
end

describe "lookup('inventory_hostnames', ...) no-match warning" do
  def run_pattern(expr : String)
    dir = File.tempname("ih-warn", ".d")
    Dir.mkdir(dir)
    inventory = File.join(dir, "inventory.ini")
    File.write(inventory, INVENTORY)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, pattern_playbook(expr))

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", inventory, playbook], output: stdout, error: stderr)
    {stdout.to_s, stderr.to_s}
  ensure
    FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
  end

  it "warns on stderr for lookup() with an unmatched pattern" do
    stdout, stderr = run_pattern("lookup('inventory_hostnames', 'nosuchgroup')")
    stdout[/TAG=(.*)"/, 1].must_equal("[]")
    stderr.includes?(warning_line("nosuchgroup")).must_equal(true)
  end

  it "warns on stderr for query() with an unmatched pattern" do
    _stdout, stderr = run_pattern("query('inventory_hostnames', 'nosuchgroup')")
    stderr.includes?(warning_line("nosuchgroup")).must_equal(true)
  end

  it "does not warn for an out-of-range subscript on matched hosts" do
    _stdout, stderr = run_pattern("lookup('inventory_hostnames', 'webservers[9]')")
    stderr.empty?.must_equal(true)
  end

  it "does not warn for exclusion or intersection terms" do
    _stdout, stderr = run_pattern("lookup('inventory_hostnames', 'all:!nosuchgroup:&alsonosuch')")
    stderr.empty?.must_equal(true)
  end

  it "warns once for the same unmatched term repeated" do
    _stdout, stderr = run_pattern("lookup('inventory_hostnames', 'nosuchgroup,nosuchgroup')")
    stderr.scan(/Could not match supplied host pattern, ignoring: nosuchgroup/).size.must_equal(1)
  end
end

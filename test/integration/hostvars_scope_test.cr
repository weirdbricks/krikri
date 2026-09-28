# Cross-host hostvars rendering scope: a value read through
# hostvars[<other host>] must render in THAT host's own variable context
# (real Ansible's HostVarsVars templar - the per-host templar ansible-core
# builds for every hostvars entry), never the reading host's. Before this
# was fixed, every re-render funnel (the span re-pass, the plain-lookup
# re-render, the extract filter, the jinja engine's hostvars preparation,
# template: vars preparation) rendered another host's templated value with
# the reading host's vars - on a two-host inventory where
# `who: "{{ myname }}"`, `hostvars['h2'].who` read from h1 came back with
# h1's `myname`.
require "../minitest_helper"
require "file_utils"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-hostvars-scope.ini")

private def run_scope_playbook : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(
    BINARY,
    ["-i", INVENTORY, File.join(PROJECT_ROOT, "test", "fixtures", "hostvars-scope-playbook.yml")],
    output: output,
    error: output
  )
  {status, output.to_s}
end

describe "hostvars[<other host>] renders in the other host's own context" do
  it "renders bare spans and list-literal elements per host" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    # h1 reading: its own who=one, h1's=one, h2's=two, own nm=h1, h2's nm=h2
    output.must_include("bare=one|one|two|h1|h2")
    # h2 reading: its own who=two, h1's=one, h2's=two, own nm=h2, h2's nm=h2
    output.must_include("bare=two|one|two|h2|h2")
    output.must_include("list=[one,two,h1,h1]")
    output.must_include("list=[two,two,h2,h1]")
  end

  it "renders the extract filter's hostvars entries per host" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    output.must_include("extract=one,two")
  end

  it "renders hostvars[item] per host in a loop" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    output.must_include("loop=h1=one")
    output.must_include("loop=h2=two")
  end

  it "compares another host's rendered value in when:" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    # hostvars['h2'].who == 'two' is true from BOTH hosts
    output.must_include("when=hit")
  end

  it "stores the other host's rendered value via set_fact" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    output.must_include("one-h2")
  end

  it "renders the referenced host's context under delegate_to" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    output.must_include("delegate=two")
  end

  it "renders nested containers and method calls per host" do
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    output.must_include("nested=two-cfg|two-1+two-2")
  end

  it "renders a template: .j2 file's hostvars reads per host" do
    dests = ["h1", "h2"].map { |host| "/tmp/krikri-hv-scope-#{host}.txt" }
    dests.each { |dest| File.delete(dest) if File.exists?(dest) }
    status, output = run_scope_playbook
    status.success?.must_equal(true, output)
    begin
      File.read("/tmp/krikri-hv-scope-h1.txt").must_include("h1=one h2=two self=one nm=h2")
      File.read("/tmp/krikri-hv-scope-h2.txt").must_include("h1=one h2=two self=two nm=h2")
    ensure
      dests.each { |dest| File.delete(dest) if File.exists?(dest) }
    end
  end
end

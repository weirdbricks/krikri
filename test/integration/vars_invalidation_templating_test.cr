require "../minitest_helper"
require "file_utils"

# Invalidation regressions for templating against LIVE vars, at the
# playbook level: every scenario below changes the vars between two
# templating operations INSIDE one task execution flow (set_fact,
# register, loop item binding, include_vars) and asserts the SECOND
# substitution renders the NEW value. A stale snapshot taken at the
# first substitution - the failure mode any future "cache the
# substitutor per task" optimization would introduce - makes the
# second render repeat the FIRST value, which is exactly what these
# specs pin against.
#
# The controller-profile candidate-2 work (vars-hash dup / second
# substitutor) kept this property by making the substitutor's view of
# the vars hash live (copy-on-write: alias for reads, dup only when a
# write is actually needed) instead of adding an invalidation-keyed
# cache.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private PLAY_HEADER = [
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
  "  tasks:",
]

private def run_play(tasks : Array(String)) : {Bool, String}
  playbook = File.tempname("vars-invalidation", ".yml")
  File.write(playbook, (PLAY_HEADER + tasks).join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "templating sees vars changed between two substitutions in the same play" do
  it "set_fact then use: the second set_fact's value wins" do
    success, output = run_play([
      "    - set_fact: x=\"first\"",
      "    - debug: msg=\"v={{ x }}\"",
      "    - set_fact: x=\"second\"",
      "    - debug: msg=\"v={{ x }}\"",
    ])
    success.must_equal(true, output)
    output.must_include("v=first")
    output.must_include("v=second")
    # A stale cache repeats the first render's value for every later
    # substitution of the same text.
    output.scan("v=first").size.must_equal(1)
  end

  it "loop item change: each iteration renders its OWN item" do
    success, output = run_play([
      "    - debug: msg=\"item={{ item }}\"",
      "      loop: [one, two, three]",
    ])
    success.must_equal(true, output)
    output.must_include("item=one")
    output.must_include("item=two")
    output.must_include("item=three")
    # The task banner also echoes the item label, so count the rendered
    # MSG body only: a stale snapshot repeats item ONE for every
    # iteration and never renders two/three at all.
    output.scan(%(msg": "item=three")).size.must_equal(1)
  end

  it "register then use: the re-registered result's new value is visible" do
    success, output = run_play([
      "    - debug: msg=\"one\"",
      "      register: r",
      "    - debug: msg=\"got={{ r.msg }}\"",
      "    - debug: msg=\"two\"",
      "      register: r",
      "    - debug: msg=\"got={{ r.msg }}\"",
    ])
    success.must_equal(true, output)
    output.scan("got=one").size.must_equal(1)
    output.scan("got=two").size.must_equal(1)
  end

  it "include_vars then use, twice: the second file's value wins" do
    dir = PluginSpecHelper.tmp_path("vars-invalidation-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.yml"), "iv: first\n")
    File.write(File.join(dir, "b.yml"), "iv: second\n")
    success, output = run_play([
      "    - include_vars: #{File.join(dir, "a.yml")}",
      "    - debug: msg=\"iv={{ iv }}\"",
      "    - include_vars: #{File.join(dir, "b.yml")}",
      "    - debug: msg=\"iv={{ iv }}\"",
    ])
    success.must_equal(true, output)
    output.scan("iv=first").size.must_equal(1)
    output.scan("iv=second").size.must_equal(1)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

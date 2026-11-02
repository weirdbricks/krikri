require "../minitest_helper"

# Issue #422, the fail-on-access half of Ansible's lazy-container
# behavior. A dict value whose own template bottoms out at a name set
# nowhere (`n: {a: "{{ nosuch }}"}`) must not fail a read that never
# touches it (`n.ok`), but it DOES fail the span that actually reads it -
# ansible-core renders the leaf strictly at that access (live-verified
# vs 2.19.11 on all shapes below). krikri's scope preparation defers such
# leaves (#422's untouched-sibling fix), so it must notice when the raw
# text leaks into a span's result.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_access_playbook(msg : String)
  playbook = File.tempname("deferred-leaf-access", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        n:
          a: "{{ nosuch }}"
          ok: "hello"
      tasks:
        - name: probe
          ansible.builtin.debug:
            msg: #{msg}
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "a deferred container leaf that a span reads (issue #422)" do
  it "fails an operator-combined read with the innermost missing name" do
    status, output = run_access_playbook(%("{{ n.a ~ 'x' }}"))
    status.success?.must_equal(false)
    output.must_include("Error while resolving value for 'msg': 'nosuch' is undefined")
  end

  it "fails a default()-guarded read too (ansible's default does not rescue it)" do
    status, output = run_access_playbook(%("{{ n.a | default('dflt') }}"))
    status.success?.must_equal(false)
    output.must_include("Error while resolving value for 'msg': 'nosuch' is undefined")
  end

  it "keeps a read of the rendered sibling succeeding" do
    status, output = run_access_playbook(%("{{ n.ok }}"))
    status.success?.must_equal(true)
    output.must_include(%("msg": "hello"))
  end
end

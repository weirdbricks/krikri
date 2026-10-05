require "../minitest_helper"
require "http/server"

# Runs the compiled binary against a real playbook - this is
# specifically about whether an exception raised while resolving a
# task's own arguments (ExpressionEvaluator#fetch_url_lines's lookup
# ('url', ...) HTTP-error raise) is caught somewhere in the task
# executor and converted into a normal failed task, or left to crash
# the whole process as an unhandled exception.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# The HTTP double's server/address/base were file-scoped locals in the
# classic spec; they become private constants started once at require time
# (all test files compile into one binary), like get_url_test's.
private LOOKUP_URL_FAILURE_SERVER = HTTP::Server.new do |context|
  context.response.status_code = 404
end

LOOKUP_URL_FAILURE_ADDRESS = LOOKUP_URL_FAILURE_SERVER.bind_unused_port
spawn { LOOKUP_URL_FAILURE_SERVER.listen }
Fiber.yield

private LOOKUP_URL_FAILURE_BASE = "http://#{LOOKUP_URL_FAILURE_ADDRESS}"

describe "a task whose argument resolution raises (lookup('url', ...) hitting a real HTTP error)" do
  it "fails that one task cleanly, with a normal recap and exit code, instead of crashing the whole process" do
    # Real bug found benchmarking buluma.victoriametrics (round 157):
    # once lookup('url', ...) was fixed to raise on an HTTP error
    # (matching Ansible - see url_lookup_spec.cr's own "raises on
    # a 404" spec), nothing in the call chain from execute_task_once up
    # through krikri-playbook.cr's own top-level `run` caught that
    # exception at all - it crashed the ENTIRE process with an
    # unhandled-exception Crystal stack trace instead of failing just
    # the one task, unlike Ansible (which fails the enclosing
    # set_fact: task cleanly and continues per normal when:/rescue:
    # semantics, or ends the play with the standard exit code 2).
    playbook = File.tempname("lookup-url-failure", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: this should fail cleanly, not crash
            ansible.builtin.set_fact:
              x: "{{ lookup('url', '#{LOOKUP_URL_FAILURE_BASE}/missing.txt', wantlist=True) | list }}"
          - name: never reached
            ansible.builtin.debug:
              msg: "should not print"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    output.to_s.wont_include("Unhandled exception")
    output.to_s.must_include("failed=1")
    output.to_s.wont_include("should not print")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

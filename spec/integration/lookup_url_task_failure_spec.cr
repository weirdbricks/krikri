require "../spec_helper"
require "http/server"

# Runs the compiled binary against a real playbook - this is
# specifically about whether an exception raised while resolving a
# task's own arguments (ExpressionEvaluator#fetch_url_lines's lookup
# ('url', ...) HTTP-error raise) is caught somewhere in the task
# executor and converted into a normal failed task, or left to crash
# the whole process as an unhandled exception.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

lookup_url_failure_server = HTTP::Server.new do |context|
  context.response.status_code = 404
end
lookup_url_failure_address = lookup_url_failure_server.bind_unused_port
spawn { lookup_url_failure_server.listen }
Fiber.yield

lookup_url_failure_base = "http://#{lookup_url_failure_address}"

describe "a task whose argument resolution raises (lookup('url', ...) hitting a real HTTP error)" do
  it "fails that one task cleanly, with a normal recap and exit code, instead of crashing the whole process" do
    # Real bug found benchmarking buluma.victoriametrics (round 157):
    # once lookup('url', ...) was fixed to raise on an HTTP error
    # (matching real Ansible - see url_lookup_spec.cr's own "raises on
    # a 404" spec), nothing in the call chain from execute_task_once up
    # through crystal-play.cr's own top-level `run` caught that
    # exception at all - it crashed the ENTIRE process with an
    # unhandled-exception Crystal stack trace instead of failing just
    # the one task, unlike real Ansible (which fails the enclosing
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
              x: "{{ lookup('url', '#{lookup_url_failure_base}/missing.txt', wantlist=True) | list }}"
          - name: never reached
            ansible.builtin.debug:
              msg: "should not print"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("failed=1")
    output.to_s.should_not contain("should not print")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# Ansible composes its "Valid booleans include: ..." enumeration from a
# Python SET, whose iteration order is randomized per process. A module
# runs in a fresh process per invocation, so the same module-level bool
# failure never renders the same text twice and Display's message dedupe
# cannot collapse them: a loop's identical failed items, and the same
# failure on several hosts, each print their own [ERROR] block
# (live-verified vs ansible-core 2.21.6, issue #952: five failed expect:
# items gave five blocks with five different orderings, two hosts gave
# two). The same wording raised controller-side comes from one long-lived
# process with a stable order, so real dedupes those into a single block
# (live-verified: looped set_fact cacheable: failures).
describe "ErrorBlock dedupe of Python-set-ordered messages" do
  ORIGIN = "Origin: /pb.yml:6:5"

  private def emit_twice(module_name : String, msg : String) : String
    Krikri::ErrorBlock.reset_seen
    io = IO::Memory.new
    2.times do
      Krikri::ErrorBlock.emit_to(io, Krikri::ResultDisplay.task_error_chain(module_name, msg, ORIGIN))
    end
    io.to_s
  end

  it "prints a module-composed boolean block once per result" do
    msg = "argument 'echo' is of type str and we were unable to convert to bool: The value 'xctgpb' is not a valid boolean. Valid booleans include: 'off', 1, 'true'"

    emit_twice("ansible.builtin.expect", msg).scan("[ERROR]: ").size.must_equal(2)
  end

  it "still collapses the controller-side wording, whose order never changes" do
    msg = "Task failed: The value 'badstring' is not a valid boolean. Valid booleans include: 0, 1, 'on', 'true'"

    emit_twice("ansible.builtin.set_fact", msg).scan("[ERROR]: ").size.must_equal(1)
  end

  it "still collapses an identical message without a set-ordered list" do
    emit_twice("ansible.builtin.command", "non-zero return code").scan("[ERROR]: ").size.must_equal(1)
  end
end

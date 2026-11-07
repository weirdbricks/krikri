require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# wait_for_connection's numeric args are converted with int() inside its
# controller-side action plugin before anything else, so a non-numeric
# value raises an uncaught Python ValueError that the task executor wraps
# as "Task failed: <exc>" - the fatal msg keeps that prefix while the
# [ERROR] block is the single collapsed "Task failed: <inner>" line, with
# no "Module failed." middle segment (live-verified vs ansible-core 2.21.6,
# issue #948). Its timeout failure is a normal module result and keeps the
# generic "Module failed." chain.
describe "wait_for_connection task_error_chain shapes" do
  INT_ERROR_MSG = "Task failed: invalid literal for int() with base 10: 'oeuxgr'"

  it "collapses to a single Task-failed segment for the int() ValueError" do
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.wait_for_connection", INT_ERROR_MSG, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal("invalid literal for int() with base 10: 'oeuxgr'")
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal(INT_ERROR_MSG)
  end

  it "uses the generic Module-failed chain for the timeout msg" do
    msg = "timed out waiting for ping module test: ping test failed"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.wait_for_connection", msg, "Origin: /pb.yml:6")

    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end
end

require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# set_stats has no target-side module work to do: its ACTION plugin builds
# the whole result, and an unusable data: value makes it RETURN a failed
# result rather than raise - which real's task executor wraps in an
# AnsibleActionFail, so the block carries the "Action failed." middle
# segment (live-verified against ansible-core 2.21.6).
describe "set_stats task_error_chain shape" do
  it "uses the Action-failed chain for the action plugin's data-type check" do
    msg = "The 'data' option needs to be a dictionary/hash"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.set_stats", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Action failed.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(msg)
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Action failed: " + msg)
  end
end

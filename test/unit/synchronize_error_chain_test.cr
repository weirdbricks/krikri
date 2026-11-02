require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# synchronize's two failure classes land in different layers in real
# ansible: the src/dest guard is the ACTION plugin's own AnsibleActionFail
# (raised before the module runs at all), while a bad boolean parameter
# fails inside AnsibleModule setup - so real renders an "Action failed."
# middle segment for the first and the generic "Module failed." chain for
# the second. Live-verified against ansible-core 2.19.11 (issue #746).
describe "synchronize task_error_chain shapes" do
  SYNC_SRC_DEST_MSG = "synchronize requires both src and dest parameters are set"

  it "uses the Action-failed chain for the action plugin's src/dest guard" do
    chain = Krikri::ResultDisplay.task_error_chain("ansible.posix.synchronize", SYNC_SRC_DEST_MSG, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Action failed.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(SYNC_SRC_DEST_MSG)
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Action failed: " + SYNC_SRC_DEST_MSG)
  end

  it "keeps the generic Module-failed chain for the module-setup bool failure" do
    msg = "argument 'existing_only' is of type str and we were unable to convert to bool: " +
          "The value 'ywxqvh' is not a valid boolean. Valid booleans include: 0, 1, 'yes', 'true', 't', 'f', 'y', 'false', 'n', 'off', 'on', 'no', '1', '0'"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.posix.synchronize", msg, "Origin: /pb.yml:6")

    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end
end

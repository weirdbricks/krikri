require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# template:'s validate: check is a fail_json inside the copy MODULE that
# template's action plugin delegates to, so real renders the generic
# "Module failed." chain for the bare "failed to validate" message - unlike
# template's own arg-validation failures, which are bare action failures
# with a collapsed chain. Live-verified against ansible-core 2.19.11 with
# `validate: cupsd -t -c %s` (issue #615).
describe "template task_error_chain shapes" do
  it "uses the generic Module-failed chain for the validate failure" do
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.template", "failed to validate", "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Module failed.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal("failed to validate")
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: failed to validate")
  end

  it "uses the generic Module-failed chain for the owner/group lookup failure" do
    msg = "chgrp failed: failed to look up group wheel"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.template", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Module failed.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(msg)
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end

  it "keeps the handling chain for the src miss" do
    msg = "Could not find or access 'missing.j2' on the Ansible Controller."
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.template", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(msg)
    cause.chain_reason.must_equal(Krikri::ErrorBlock::HANDLING)
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: " + msg)
  end

  it "keeps the collapsed chain for a generic message" do
    msg = "some other template failure"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.template", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(msg)
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: " + msg)
  end
end

describe "copy task_error_chain shapes" do
  it "keeps the Unexpected-AnsibleActionFail chain for the src miss without the remote_src hint" do
    # 2.21 moved the "If you are using a module ... remote_src option"
    # sentence off the not-found message, so the gate that routes copy's
    # src miss can no longer key on the hint's presence - the message
    # prefix alone decides (issue #927).
    msg = "Unexpected AnsibleActionFail error: Could not find or access 'missing.txt'\nSearched in:\n\t/pb/files/missing.txt\n\t/pb/missing.txt on the Ansible Controller."
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.copy", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Unexpected AnsibleActionFail error.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal("Could not find or access 'missing.txt'\nSearched in:\n\t/pb/files/missing.txt\n\t/pb/missing.txt on the Ansible Controller.")
  end
end

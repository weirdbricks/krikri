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

  it "uses the generic Module-failed chain for the validate-must-contain-%s refusal" do
    # The %s gate is a fail_json inside the copy MODULE, so real renders the
    # "Module failed." middle segment, not a bare action failure
    # (live-verified vs ansible-core 2.21.6 with `validate: 68`, issue #939).
    msg = "validate must contain %s: 68"
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
    # sentence off the not-found message into AnsibleFileNotFound's help
    # text, so the gate that routes copy's src miss can no longer key on
    # the hint's presence - the message prefix alone decides (issue #927).
    msg = "Unexpected AnsibleActionFail error: Could not find or access 'missing.txt'\nSearched in:\n\t/pb/files/missing.txt\n\t/pb/missing.txt on the Ansible Controller."
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.copy", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Unexpected AnsibleActionFail error.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal("Could not find or access 'missing.txt'\nSearched in:\n\t/pb/files/missing.txt\n\t/pb/missing.txt on the Ansible Controller.")
  end

  it "splits copy's not-found event out under the caused-by section" do
    # The not-found event carries AnsibleFileNotFound's help text, and an
    # event with help text never collapses into the header - so real
    # prints the collapsed header, the "Task failed: Unexpected
    # AnsibleActionFail error." segment, then the not-found text with the
    # remote_src advice appended (live-verified vs 2.21.6).
    msg = "Unexpected AnsibleActionFail error: Could not find or access '/root/cluster/subnet.env' on the Ansible Controller."
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.copy", msg, "Origin: /pb.yml:6")
    text = Krikri::ErrorBlock.format_event(chain)

    text.must_include("Task failed: Unexpected AnsibleActionFail error.\nOrigin: /pb.yml:6")
    text.must_include("\n<<< caused by >>>\n\n")
    text.must_include("Could not find or access '/root/cluster/subnet.env' on the Ansible Controller. If you are using a module and expect the file to exist on the remote, see the remote_src option.")
    chain.chain.as(Krikri::ErrorBlock::Node).chain.as(Krikri::ErrorBlock::Node)
      .help_text.must_equal(Krikri::ResultDisplay::CONTROLLER_FILE_NOT_FOUND_HELP)
  end
end

require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# unarchive has two distinct failure classes with different [ERROR] block
# chain shapes: the module-level pick_handler failure (raised by
# AnsibleModule.fail_json inside unarchive.py, so real renders the generic
# "Module failed." chain) and the controller-side src miss raised by the
# action plugin itself (single collapsed segment). Live-verified against
# ansible-core 2.19.11.
describe "unarchive task_error_chain shapes" do
  UNARCHIVE_HANDLER_MSG = %(Failed to find handler for "/tmp/x.tar". Make sure the required command to extract the file is installed.) +
                          %(\nCommand "/usr/bin/unzip" could not handle archive: boom)

  it "uses the generic Module-failed chain for the pick_handler failure" do
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.unarchive", UNARCHIVE_HANDLER_MSG, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Module failed.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(UNARCHIVE_HANDLER_MSG)
    cause.chain.must_be_nil
    # The brief line prefixes the FULL module msg (reasons included),
    # never a "Module failed" prefix on the fatal: line's own msg field.
    Krikri::ErrorBlock.brief_message(chain).must_equal(
      "Task failed: Module failed: " + UNARCHIVE_HANDLER_MSG)
  end

  it "uses the generic Module-failed chain for a URL download failure" do
    msg = "Failure downloading http://h/x.tar.gz, Request failed: <urlopen error [Errno 111] Connection refused>"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.unarchive", msg, "Origin: /pb.yml:6")

    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end

  it "keeps the collapsed chain for the controller-side src miss" do
    msg = "Task failed: Source '/x.tar' failed to transfer"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.unarchive", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal("Source '/x.tar' failed to transfer")
    cause.chain.must_be_nil
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Source '/x.tar' failed to transfer")
  end
end

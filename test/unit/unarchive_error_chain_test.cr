require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# unarchive has two distinct failure classes with different [ERROR] block
# chain shapes: the module-level pick_handler failure (raised by
# AnsibleModule.fail_json inside unarchive.py, so real renders the generic
# "Module failed." chain) and the controller-side src miss raised by the
# action plugin itself (the collapsed header plus the chained not-found
# event under its own caused-by section). Live-verified against
# ansible-core 2.21.6.
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

  it "uses the generic Module-failed chain for an unpack failure" do
    msg = "failed to unpack /root/.ansible/tmp/x to /usr/bin"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.unarchive", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Module failed.")
    cause = middle.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(msg)
    cause.chain.must_be_nil
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

  it "splits the controller-side not-found event out with its help paragraph" do
    # ansible-core 2.21 moved the remote_src sentence off the message into
    # AnsibleFileNotFound's help text, which stops the not-found event
    # collapsing into the header: real prints the header, the bare "Task
    # failed." segment, then the caused-by text and the advice as its own
    # paragraph (live-verified vs 2.21.6).
    not_found = "Could not find or access '/x.tar'\nSearched in:\n\t/pb/files/x.tar on the Ansible Controller."
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.unarchive", "Task failed: #{not_found}", "Origin: /pb.yml:6")
    text = Krikri::ErrorBlock.format_event(chain)

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(not_found)
    cause.help_text.must_equal(Krikri::ResultDisplay::CONTROLLER_FILE_NOT_FOUND_HELP)
    text.must_include("\nTask failed.\nOrigin: /pb.yml:6\n")
    text.must_include("\n<<< caused by >>>\n\n#{not_found}\n\n")
    text.must_include("\nIf you are using a module and expect the file to exist on the remote, see the remote_src option.\n")
  end

  it "uses the generic Module-failed chain for the module's own missing-src gate" do
    # With remote_src: truthy the action plugin hands the task straight to
    # the module, whose main() fails the same missing src with its own
    # "Source '<src>' does not exist" (module.fail_json, live-verified vs
    # 2.19.11) - a module-level failure, so real renders the generic
    # "Module failed." middle segment, not the collapsed action shape.
    msg = "Source '/x.tar' does not exist"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.unarchive", msg, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    middle = chain.chain.as(Krikri::ErrorBlock::Node)
    middle.msg.must_equal("Module failed.")
    middle.chain.as(Krikri::ErrorBlock::Node).msg.must_equal(msg)
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end
end

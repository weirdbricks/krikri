require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# An uncaught exception from a raw-run Python module (py_module's crash
# result) renders through the generic chain: real ansible's AnsiballZ loader
# catches the Exception and fails the task with the collapsed one-segment
# block - brief "Task failed: Module failed: <msg>" at the task's Origin,
# no second paragraph and no "<<< caused by >>>" section, the same shape a
# plain fail_json gets (live-verified vs ansible-playbook 2.19, issue #523).
describe "uncaught module exception error block" do
  it "renders the flat collapsed block with no caused-by section" do
    chain = Krikri::ResultDisplay.task_error_chain(
      "ansible.builtin.some_custom_module", "No module named 'docker'", "Origin: /pb.yml:6")

    text = Krikri::ErrorBlock.format_event(chain)
    text.must_include("Task failed: Module failed: No module named 'docker'")
    text.wont_include("<<< caused by >>>")
    text.wont_include("<<< while handling >>>")
  end

  it "renders the message-less exception flat as well" do
    chain = Krikri::ResultDisplay.task_error_chain(
      "ansible.builtin.some_custom_module", "", "Origin: /pb.yml:6")

    text = Krikri::ErrorBlock.format_event(chain)
    text.must_include("Task failed: Module failed.")
    text.wont_include("<<< caused by >>>")
  end

  it "splits the block when the crash exception carried an implicit context" do
    # Python links an exception raised inside an `except` block to the one
    # it interrupted; ansible-core 2.21 (live-verified) prints the
    # "Module failed." segment with its Origin and then a caused-by section
    # whose leaf is the crash message, blank when the exception had none
    # (community.general.nsupdate's dnspython ValueError for a non-IP
    # server, kpg 000015-multi-pam_limits-chaos).
    chain = Krikri::ResultDisplay.task_error_chain(
      "community.general.nsupdate", "", "Origin: /pb.yml:6", crash_context: true)

    text = Krikri::ErrorBlock.format_event(chain)
    text.must_equal("Task failed: Module failed.\n\n" +
                    "Task failed: Module failed.\nOrigin: /pb.yml:6\n\n" +
                    "<<< caused by >>>\n\n")
    text.wont_include("<<< while handling >>>")
  end

  it "keeps the crash detail as the caused-by leaf when the exception had a msg" do
    chain = Krikri::ResultDisplay.task_error_chain(
      "ansible.builtin.some_custom_module", "Task failed: Module failed: wrapped in context",
      "Origin: /pb.yml:6", crash_context: true)

    text = Krikri::ErrorBlock.format_event(chain)
    text.must_equal("Task failed: Module failed: wrapped in context\n\n" +
                    "Task failed: Module failed.\nOrigin: /pb.yml:6\n\n" +
                    "<<< caused by >>>\n\nwrapped in context\n\n")
  end
end

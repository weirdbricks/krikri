require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# The controller refuses a module result carrying a string that cannot be
# encoded as UTF-8 - slurp's armor=false hands back raw file bytes decoded
# with surrogateescape (issue #1801). Real raises an AnsibleRuntimeError
# while DESERIALIZING the result, with the MODULE_STRICT_UTF8_RESPONSE
# help_text, and the task executor wraps it in an AnsibleTaskError: the
# [ERROR] block is the two-segment "Task failed." + "<<< caused by >>>"
# shape whose cause line carries the help text inline, and the brief is
# "Task failed: <refusal>" with no "Module failed." middle segment
# (live-verified vs ansible-core 2.21.6).
describe "slurp invalid-UTF8 refusal error chain" do
  REFUSAL = "Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode character '\\udcff' in position 12: surrogates not allowed"

  it "renders the help text inline under the caused-by separator" do
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.slurp", REFUSAL, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal(REFUSAL)
    cause.help_text.must_equal("This check can be disabled with the `MODULE_STRICT_UTF8_RESPONSE` setting.")
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: #{REFUSAL}")
    Krikri::ErrorBlock.format_event(chain).must_equal(
      "Task failed: #{REFUSAL}\n\n" \
      "Task failed.\nOrigin: /pb.yml:6\n\n" \
      "<<< caused by >>>\n\n" \
      "#{REFUSAL} This check can be disabled with the `MODULE_STRICT_UTF8_RESPONSE` setting.\n\n"
    )
  end
end

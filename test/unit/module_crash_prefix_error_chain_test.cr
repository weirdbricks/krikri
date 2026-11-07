require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

# A module's uncaught-exception crash reaches the display with the module
# API's wrapper prefix already baked into its wire msg, exactly as real
# ansible's fatal msg carries it - e.g. lineinfile/blockinfile/replace's
# unknown-codec crash ("Task failed: Module failed: unknown encoding: 27",
# live-verified vs ansible-core 2.21.6, issue #949). The [ERROR] block must
# render that msg once, not re-prefix it.
describe "task_error_chain with a pre-prefixed module-crash msg" do
  MSG = "Task failed: Module failed: unknown encoding: 27"

  it "renders the wrapper prefix once instead of doubling it" do
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.blockinfile", MSG, "Origin: /pb.yml:6")

    chain.msg.must_equal("Task failed.")
    cause = chain.chain.as(Krikri::ErrorBlock::Node)
    cause.msg.must_equal("Module failed.")
    cause.chain.as(Krikri::ErrorBlock::Node).msg.must_equal("unknown encoding: 27")
    Krikri::ErrorBlock.brief_message(chain).must_equal(MSG)
  end
end

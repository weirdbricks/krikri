require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"

describe "failed final rename error split" do
  it "splits the atomic_move detail at its errno text" do
    msg = "Unable to make b'/root/.ansible/tmp/x/source into to '/etc/hosts', failed final rename from '/etc/.ansible_tmpabcdefghosts': [Errno 16] Device or resource busy: b'/etc/.ansible_tmpabcdefghosts' -> b'/etc/hosts'"
    split = Krikri::ResultDisplay.failed_final_rename_split(msg)
    split.wont_be_nil
    inner, errno_text = split || {"", ""}
    inner.must_equal("Unable to make b'/root/.ansible/tmp/x/source into to '/etc/hosts', failed final rename from '/etc/.ansible_tmpabcdefghosts'")
    errno_text.must_equal("[Errno 16] Device or resource busy: b'/etc/.ansible_tmpabcdefghosts' -> b'/etc/hosts'")
  end

  it "keeps the detail and the errno as separate chain segments under Module failed" do
    msg = "Unable to make b'/r/source' into to '/etc/hosts', failed final rename from '/etc/.ansible_tmpabcdefghosts': [Errno 16] Device or resource busy: b'/etc/.ansible_tmpabcdefghosts' -> b'/etc/hosts'"
    chain = Krikri::ResultDisplay.task_error_chain("ansible.builtin.template", msg, "Origin: /pb.yml:6")

    module_failed = chain.chain.as(Krikri::ErrorBlock::Node)
    module_failed.msg.must_equal("Module failed.")
    detail = module_failed.chain.as(Krikri::ErrorBlock::Node)
    detail.msg.must_equal("Unable to make b'/r/source' into to '/etc/hosts', failed final rename from '/etc/.ansible_tmpabcdefghosts'.")
    detail.chain.as(Krikri::ErrorBlock::Node).msg.starts_with?("[Errno 16] ").must_equal(true)
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end

  it "ignores unrelated messages" do
    Krikri::ResultDisplay.failed_final_rename_split("something else: [Errno 2] x").must_be_nil
  end
end

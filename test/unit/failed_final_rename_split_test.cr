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

  it "splits the plain-repr src spelling authorized_key echoes" do
    # authorized_key's writefile hands atomic_move a str /tmp mkstemp path,
    # so real's crash reprs it plain ('...') - not the copy module's bytes
    # b'...' spelling (issue #819's authorized_keys EBUSY crash).
    msg = "Unable to make '/tmp/tmp70q862b2' into to '/root/.ssh/authorized_keys', failed final rename from '/root/.ssh/.ansible_tmpv4kzu62lauthorized_keys': [Errno 16] Device or resource busy: b'/root/.ssh/.ansible_tmpv4kzu62lauthorized_keys' -> b'/root/.ssh/authorized_keys'"
    split = Krikri::ResultDisplay.failed_final_rename_split(msg)
    split.wont_be_nil
    inner, errno_text = split || {"", ""}
    inner.must_equal("Unable to make '/tmp/tmp70q862b2' into to '/root/.ssh/authorized_keys', failed final rename from '/root/.ssh/.ansible_tmpv4kzu62lauthorized_keys'")
    errno_text.must_equal("[Errno 16] Device or resource busy: b'/root/.ssh/.ansible_tmpv4kzu62lauthorized_keys' -> b'/root/.ssh/authorized_keys'")

    chain = Krikri::ResultDisplay.task_error_chain("ansible.posix.authorized_key", msg, "Origin: /pb.yml:13")
    module_failed = chain.chain.as(Krikri::ErrorBlock::Node)
    module_failed.msg.must_equal("Module failed.")
    detail = module_failed.chain.as(Krikri::ErrorBlock::Node)
    detail.msg.must_equal("Unable to make '/tmp/tmp70q862b2' into to '/root/.ssh/authorized_keys', failed final rename from '/root/.ssh/.ansible_tmpv4kzu62lauthorized_keys'.")
    detail.chain.as(Krikri::ErrorBlock::Node).msg.starts_with?("[Errno 16] ").must_equal(true)
    Krikri::ErrorBlock.brief_message(chain).must_equal("Task failed: Module failed: " + msg)
  end

  it "renders the errno segment with no empty Sub-Event box" do
    # Real gates the Sub-Event box on Python truthiness (`if event.events:`),
    # so the errno node's empty events list - used only as a collapse
    # barrier - prints no box at all (issue #1164's role round: krikri
    # emitted a bare "+--[ End Sub-Event ]---" after the errno segment
    # where ansible 2.19.11 printed nothing between it and the fatal line).
    msg = "Unable to make b'/r/source' into to '/etc/hosts', failed final rename from '/etc/.ansible_tmpabcdefghosts': [Errno 16] Device or resource busy: b'/etc/.ansible_tmpabcdefghosts' -> b'/etc/hosts'"
    rendered = Krikri::ErrorBlock.format_event(
      Krikri::ResultDisplay.task_error_chain("ansible.builtin.template", msg, "Origin: /pb.yml:6")
    )

    rendered.includes?("End Sub-Event").must_equal(false)
    rendered.includes?("<<< caused by >>>").must_equal(true)
    rendered.includes?("[Errno 16] Device or resource busy").must_equal(true)
  end

  it "ignores unrelated messages" do
    Krikri::ResultDisplay.failed_final_rename_split("something else: [Errno 2] x").must_be_nil
  end
end

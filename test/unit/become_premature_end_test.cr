require "../minitest_helper"
require "../../src/krikri/plugin_manager"

describe "Krikri::PluginManager.become_premature_end_result (become_premature_end_test.cr)" do
  it "words an empty-stdout sudo failure like ansible's become failure" do
    result = Krikri::PluginManager.become_premature_end_result("", "sudo: a password is required\n")
    result.must_be_instance_of(JSON::Any)
    result = result.as(JSON::Any)
    result["msg"].as_s.must_equal("Task failed: Premature end of stream waiting for become success.\n>>> Standard Error\nsudo: a password is required")
    result["_connection_failure"].as_bool.must_equal(true)
    result["failed"].as_bool.must_equal(true)
  end

  it "leaves a silent or output-bearing failure to the generic parse error" do
    Krikri::PluginManager.become_premature_end_result("", "").must_be_nil
    Krikri::PluginManager.become_premature_end_result("garbage", "sudo: boom").must_be_nil
  end
end

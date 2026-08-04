require "../spec_helper"

private def that_json(*conditions : String) : String
  conditions.to_a.to_json
end

describe "assert plugin" do
  it "requires that:" do
    result = PluginSpecHelper.run("assert", {} of String => String)
    result["failed"].as_bool.should be_true
  end

  it "passes when every condition is true, with the default success message" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("1 == 1", "2 == 2")})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq("All assertions passed")
  end

  it "fails at the first failing condition, with the default failure message" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("my_param <= 100", "my_param >= 0")}, {"my_param" => "150"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Assertion failed")
    result["assertion"].as_s.should eq("my_param <= 100")
    result["evaluated_to"].as_bool.should be_false
  end

  it "uses a custom fail_msg" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("false"), "fail_msg" => "custom failure"})
    result["msg"].as_s.should eq("custom failure")
  end

  it "accepts msg as an alias for fail_msg" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("false"), "msg" => "via alias"})
    result["msg"].as_s.should eq("via alias")
  end

  it "uses a custom success_msg" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("true"), "success_msg" => "all good"})
    result["msg"].as_s.should eq("all good")
  end

  it "evaluates a {{ }}-wrapped condition with dotted variable access" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("{{ my_param > 100 }}")}, {"my_param" => "150"})
    result["failed"].as_bool.should be_false
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("assert", {"that" => that_json("true")})
    result["changed"].as_bool.should be_false
  end
end

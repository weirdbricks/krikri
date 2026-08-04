require "../spec_helper"

describe "set_fact plugin" do
  it "returns given params as ansible_facts, unchanged" do
    result = PluginSpecHelper.run("set_fact", {"greeting" => "hi"})

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    result["ansible_facts"]["greeting"].as_s.should eq("hi")
  end

  it "coerces bool-looking and int-looking values, and leaves other strings alone" do
    result = PluginSpecHelper.run("set_fact", {
      "is_ready" => "true", "is_done" => "false", "count" => "3", "ratio" => "1.5", "name" => "web01",
    })

    facts = result["ansible_facts"]
    facts["is_ready"].as_bool.should be_true
    facts["is_done"].as_bool.should be_false
    facts["count"].as_i64.should eq(3)
    facts["ratio"].as_f.should eq(1.5)
    facts["name"].as_s.should eq("web01")
  end

  it "does not turn cacheable: into a literal fact" do
    result = PluginSpecHelper.run("set_fact", {"greeting" => "hi", "cacheable" => "yes"})

    result["ansible_facts"].as_h.has_key?("cacheable").should be_false
  end
end

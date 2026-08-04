require "../spec_helper"

describe "pause plugin" do
  it "sleeps for the given seconds" do
    started = Time.monotonic
    result = PluginSpecHelper.run("pause", {"seconds" => "1"})
    elapsed = Time.monotonic - started

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    result["stdout"].as_s.should eq("Paused for 1.0 seconds")
    result["delta"].as_i.should eq(1)
    elapsed.total_seconds.should be >= 1.0
  end

  it "sleeps for the given minutes, converted to seconds" do
    result = PluginSpecHelper.run("pause", {"minutes" => "0.02"})
    result["stdout"].as_s.should eq("Paused for 0.02 minutes")
    result["delta"].as_i.should be >= 1
  end

  it "fails when both seconds and minutes are given" do
    result = PluginSpecHelper.run("pause", {"seconds" => "1", "minutes" => "1"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: minutes|seconds")
  end

  it "continues immediately when neither seconds nor minutes is given" do
    started = Time.monotonic
    result = PluginSpecHelper.run("pause", {} of String => String)
    elapsed = Time.monotonic - started

    result["failed"].as_bool.should be_false
    elapsed.total_seconds.should be < 1.0
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("pause", {"seconds" => "0"})
    result["changed"].as_bool.should be_false
  end
end

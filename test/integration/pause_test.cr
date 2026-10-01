require "../minitest_helper"

describe "pause plugin" do
  it "sleeps for the given seconds" do
    started = Time.instant
    result = PluginSpecHelper.run("pause", {"seconds" => "1"})
    elapsed = Time.instant - started

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["stdout"].as_s.must_equal("Paused for 1.0 seconds")
    result["delta"].as_i.must_equal(1)
    (elapsed.total_seconds >= 1.0).must_equal(true)
  end

  it "sleeps for the given minutes, converted to seconds" do
    result = PluginSpecHelper.run("pause", {"minutes" => "0.02"})
    result["stdout"].as_s.must_equal("Paused for 0.02 minutes")
    (result["delta"].as_i >= 1).must_equal(true)
  end

  it "fails when both seconds and minutes are given" do
    result = PluginSpecHelper.run("pause", {"seconds" => "1", "minutes" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: minutes|seconds")
  end

  it "continues immediately when neither seconds nor minutes is given" do
    started = Time.instant
    result = PluginSpecHelper.run("pause", {} of String => String)
    elapsed = Time.instant - started

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    (elapsed.total_seconds < 1.0).must_equal(true)
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("pause", {"seconds" => "0"})
    result["changed"].as_bool.must_equal(false)
  end
end

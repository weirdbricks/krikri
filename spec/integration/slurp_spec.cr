require "../spec_helper"
require "file_utils"
require "base64"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "slurp plugin" do
  it "returns a file's content base64-encoded by default (armor: true)" do
    path = tmp_path("slurp_armored.txt")
    File.write(path, "hello slurp")

    result = PluginSpecHelper.run("slurp", {"src" => path})

    result["failed"].as_bool.should be_false
    result["encoding"].as_s.should eq("base64")
    Base64.decode_string(result["content"].as_s).should eq("hello slurp")
    result["source"].as_s.should eq(path)
  end

  it "returns raw utf-8 content when armor: false" do
    path = tmp_path("slurp_plain.txt")
    File.write(path, "plain text")

    result = PluginSpecHelper.run("slurp", {"src" => path, "armor" => "false"})

    result["failed"].as_bool.should be_false
    result["encoding"].as_s.should eq("utf-8")
    result["content"].as_s.should eq("plain text")
  end

  it "accepts the path alias for src" do
    path = tmp_path("slurp_alias.txt")
    File.write(path, "aliased")

    result = PluginSpecHelper.run("slurp", {"path" => path})

    result["failed"].as_bool.should be_false
    Base64.decode_string(result["content"].as_s).should eq("aliased")
  end

  it "fails with a clear message for a missing file" do
    result = PluginSpecHelper.run("slurp", {"src" => tmp_path("does-not-exist-slurp.txt")})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("File not found")
  end

  it "fails with a clear message when src is a directory" do
    dir = tmp_path("slurp_dir")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("slurp", {"src" => dir})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("directory")
  end
end

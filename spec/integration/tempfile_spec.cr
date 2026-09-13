require "../spec_helper"

describe "tempfile plugin" do
  it "creates a temporary file by default and reports changed" do
    result = PluginSpecHelper.run("tempfile", {} of String => String)

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    path = result["path"].as_s
    File.exists?(path).should be_true
    File.file?(path).should be_true
    File.delete(path)
  end

  it "creates a temporary directory when state: directory" do
    result = PluginSpecHelper.run("tempfile", {"state" => "directory"})

    result["failed"]?.try(&.as_bool).should be_falsey
    path = result["path"].as_s
    Dir.exists?(path).should be_true
    Dir.delete(path)
  end

  it "honors prefix and suffix" do
    result = PluginSpecHelper.run("tempfile", {"prefix" => "myapp.", "suffix" => ".conf"})

    path = result["path"].as_s
    File.basename(path).should start_with("myapp.")
    File.basename(path).should end_with(".conf")
    File.delete(path)
  end

  it "creates the file under path: when given" do
    dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("tempfile", {"path" => dir})

    path = result["path"].as_s
    File.dirname(path).should eq(dir)
    File.delete(path)
  end

  it "fails for an invalid state" do
    result = PluginSpecHelper.run("tempfile", {"state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: file, directory, got: bogus")
  end

  it "fails when path: doesn't exist" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all"})

    result["failed"].as_bool.should be_true
  end
end

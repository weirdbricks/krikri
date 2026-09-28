require "../minitest_helper"

describe "tempfile plugin" do
  it "creates a temporary file by default and reports changed" do
    result = PluginSpecHelper.run("tempfile", {} of String => String)

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    path = result["path"].as_s
    File.exists?(path).must_equal(true)
    File.file?(path).must_equal(true)
    File.delete(path)
  end

  it "creates a temporary directory when state: directory" do
    result = PluginSpecHelper.run("tempfile", {"state" => "directory"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    path = result["path"].as_s
    Dir.exists?(path).must_equal(true)
    Dir.delete(path)
  end

  it "honors prefix and suffix" do
    result = PluginSpecHelper.run("tempfile", {"prefix" => "myapp.", "suffix" => ".conf"})

    path = result["path"].as_s
    File.basename(path).starts_with?("myapp.").must_equal(true)
    File.basename(path).ends_with?(".conf").must_equal(true)
    File.delete(path)
  end

  it "creates the file under path: when given" do
    dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("tempfile", {"path" => dir})

    path = result["path"].as_s
    File.dirname(path).must_equal(dir)
    File.delete(path)
  end

  it "fails for an invalid state" do
    result = PluginSpecHelper.run("tempfile", {"state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: file, directory, got: bogus")
  end

  it "fails when path: doesn't exist" do
    result = PluginSpecHelper.run("tempfile", {"path" => "/no/such/dir/at/all"})

    result["failed"].as_bool.must_equal(true)
  end
end

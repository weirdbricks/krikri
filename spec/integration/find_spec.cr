require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "find")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(File.join(TMP_DIR, "sub", "subsub"))
  File.write(File.join(TMP_DIR, "a.txt"), "a")
  File.write(File.join(TMP_DIR, "b.log"), "b")
  File.write(File.join(TMP_DIR, "sub", "c.txt"), "c")
  File.write(File.join(TMP_DIR, "sub", ".hidden.txt"), "hidden")
  File.write(File.join(TMP_DIR, "sub", "subsub", "d.txt"), "d")
end

private def paths_of(result : JSON::Any) : Array(String)
  result["files"].as_a.map(&.["path"].as_s).sort!
end

describe "find plugin" do
  it "matches top-level files only, non-recursively, by default" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.txt"})

    result["matched"].as_i64.should eq(1)
    paths_of(result).should eq([File.join(TMP_DIR, "a.txt")])
  end

  it "recurses into subdirectories when recurse: true" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.txt", "recurse" => "true"})

    paths_of(result).should eq([
      File.join(TMP_DIR, "a.txt"),
      File.join(TMP_DIR, "sub", "c.txt"),
      File.join(TMP_DIR, "sub", "subsub", "d.txt"),
    ].sort)
  end

  it "excludes hidden files by default, even when recursing" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.txt", "recurse" => "true"})

    paths_of(result).should_not contain(File.join(TMP_DIR, "sub", ".hidden.txt"))
  end

  it "includes hidden files when hidden: true" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.txt", "recurse" => "true", "hidden" => "true"})

    paths_of(result).should contain(File.join(TMP_DIR, "sub", ".hidden.txt"))
  end

  it "does not exclude anything when excludes is unset (regression: an empty excludes list must not exclude everything)" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.txt"})

    result["matched"].as_i64.should eq(1)
  end

  it "filters out basenames matching excludes" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*", "excludes" => "*.log"})

    paths_of(result).should_not contain(File.join(TMP_DIR, "b.log"))
    paths_of(result).should contain(File.join(TMP_DIR, "a.txt"))
  end

  it "matches directories when file_type: directory" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "file_type" => "directory", "recurse" => "true"})

    paths_of(result).should eq([File.join(TMP_DIR, "sub"), File.join(TMP_DIR, "sub", "subsub")].sort)
  end

  it "limits recursion depth when depth is set" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.txt", "recurse" => "true", "depth" => "1"})

    paths_of(result).should eq([File.join(TMP_DIR, "a.txt")])
  end

  it "reports a skipped path for a nonexistent search directory" do
    missing = File.join(TMP_DIR, "does-not-exist")
    result = PluginSpecHelper.run("find", {"paths" => missing})

    result["matched"].as_i64.should eq(0)
    result["skipped_paths"].as_h.has_key?(missing).should be_true
  end

  it "fails with a clear message when paths is missing" do
    result = PluginSpecHelper.run("find", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("paths")
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("find", {"paths" => TMP_DIR})

    result["changed"].as_bool.should be_false
  end
end

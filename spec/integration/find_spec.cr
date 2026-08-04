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

  describe "age" do
    it "matches files at least the given age (positive)" do
      old_path = File.join(TMP_DIR, "old.age")
      File.write(old_path, "x")
      File.utime(Time.utc - 2.days, Time.utc - 2.days, old_path)

      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "*.age", "age" => "1d"})

      paths_of(result).should eq([old_path])
    end

    it "matches files at most the given age (negative)" do
      new_path = File.join(TMP_DIR, "new.age")
      File.write(new_path, "x")

      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "new.age", "age" => "-1d"})

      paths_of(result).should eq([new_path])
    end

    it "compares against age_stamp: ctime/atime instead of the mtime default" do
      path = File.join(TMP_DIR, "stamped.age")
      File.write(path, "x")
      # ctime can't be set directly, but a file this fresh should always
      # be well under 1 day old by any of the three timestamps.
      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "stamped.age", "age" => "1d", "age_stamp" => "ctime"})

      paths_of(result).should eq([] of String)
    end
  end

  describe "contains" do
    it "matches a file whose content matches the regex, line-anchored by default" do
      path = File.join(TMP_DIR, "needle-start.contains")
      File.write(path, "needle at line start\n")

      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "needle-start.contains", "contains" => "needle"})

      paths_of(result).should eq([path])
    end

    it "does not match when the pattern is present but not at the start of any line" do
      path = File.join(TMP_DIR, "needle-mid.contains")
      File.write(path, "prefix needle-not-at-start\n")

      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "needle-mid.contains", "contains" => "needle"})

      paths_of(result).should eq([] of String)
    end

    it "matches mid-line content when read_whole_file: true" do
      path = File.join(TMP_DIR, "needle-mid2.contains")
      File.write(path, "prefix needle-not-at-start\n")

      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "needle-mid2.contains", "contains" => "needle", "read_whole_file" => "true"})

      paths_of(result).should eq([path])
    end

    it "excludes files whose content doesn't match" do
      path = File.join(TMP_DIR, "no-match.contains")
      File.write(path, "nothing relevant here\n")

      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "patterns" => "no-match.contains", "contains" => "needle"})

      paths_of(result).should eq([] of String)
    end

    it "is ignored when file_type is not file (contains only applies to regular files)" do
      result = PluginSpecHelper.run("find", {"paths" => TMP_DIR, "file_type" => "directory", "contains" => "needle"})

      paths_of(result).should_not be_empty
    end
  end
end

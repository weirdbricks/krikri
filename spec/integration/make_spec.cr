require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "make_spec")

describe "make plugin" do
  it "runs the default target, then reports unchanged on a second identical run (real Ansible's own -q idempotency check)" do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), <<-MAKEFILE)
      all: output.txt

      output.txt:
      \ttouch output.txt
      MAKEFILE
    File.delete(File.join(TMP_DIR, "output.txt")) if File.exists?(File.join(TMP_DIR, "output.txt"))

    result = PluginSpecHelper.run("make", {"chdir" => TMP_DIR})
    result["changed"].as_bool.should be_true
    File.exists?(File.join(TMP_DIR, "output.txt")).should be_true

    result2 = PluginSpecHelper.run("make", {"chdir" => TMP_DIR})
    result2["changed"].as_bool.should be_false
  end

  it "runs a specific target: " do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), <<-MAKEFILE)
      all: output.txt

      output.txt:
      \ttouch output.txt

      clean:
      \trm -f output.txt
      MAKEFILE
    File.write(File.join(TMP_DIR, "output.txt"), "")

    result = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "clean"})
    result["changed"].as_bool.should be_true
    File.exists?(File.join(TMP_DIR, "output.txt")).should be_false
  end

  it "requires chdir" do
    result = PluginSpecHelper.run("make", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("chdir")
  end
end

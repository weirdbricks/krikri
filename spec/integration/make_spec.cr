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

  it "requires chdir, with parameters.py's plural wording" do
    result = PluginSpecHelper.run("make", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: chdir")
  end

  it "rejects target and targets together with real's mutually-exclusive wording" do
    Dir.mkdir_p(TMP_DIR)
    result = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "all", "targets" => "all"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: target|targets")
  end

  it "carries the shlex-quoted base command in `command` (no msg), resolving gmake first like real get_bin_path" do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), "all:\n\t@echo built-all\n")

    result = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "all"})

    result["changed"].as_bool.should be_true
    result["msg"]?.should be_nil
    result["command"].as_s.should eq("/usr/bin/gmake all")
    result["stdout"].as_s.should eq("built-all")
  end

  it "uses an explicit make: binary path verbatim" do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), "all:\n\t@echo built-all\n")

    result = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "all", "make" => "/usr/bin/make"})

    result["command"].as_s.should eq("/usr/bin/make all")
  end

  it "places jobs before the target and str()-formats params (bare key for None)" do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), "all:\n\t@echo built-all\n")

    result = PluginSpecHelper.run("make", {
      "chdir"  => TMP_DIR,
      "target" => "all",
      "jobs"   => "2",
      "params" => %({"NUM_THREADS": 4, "EXTRA": "y"}),
    })

    result["command"].as_s.should eq("/usr/bin/gmake -j 2 all NUM_THREADS=4 EXTRA=y")
  end

  it "fails a failing target with check_rc's shape: the sanitized stderr as msg plus rc" do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), "fail:\n\t@echo about-to-fail >&2\n\t@exit 2\n")

    result = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "fail"})

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["rc"].as_i.should eq(2)
    result["msg"].as_s.should contain("about-to-fail")
    result["msg"].as_s.should contain("Error 2")
  end

  it "check mode reports changed from the -q probe with no msg" do
    Dir.mkdir_p(TMP_DIR)
    File.write(File.join(TMP_DIR, "Makefile"), "all:\n\t@echo built-all\n")

    stale = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "all", "check_mode" => "true"})
    stale["changed"].as_bool.should be_true
    stale["msg"]?.should be_nil

    File.write(File.join(TMP_DIR, "Makefile"), "out.txt:\n\t@echo rebuilt > out.txt\nall:\n\t@echo built-all\n")
    PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "out.txt"})
    fresh = PluginSpecHelper.run("make", {"chdir" => TMP_DIR, "target" => "out.txt", "check_mode" => "true"})
    fresh["changed"].as_bool.should be_false
    fresh["msg"]?.should be_nil
  end
end

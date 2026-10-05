require "../minitest_helper"

# The classic suite used a fixed shared spec/tmp/make_spec dir; every test
# now gets its own tmp_path subtree (concurrent make tests clobbered each
# other's Makefile/output.txt under -p 4).
describe "make plugin" do
  it "runs the default target, then reports unchanged on a second identical run (Ansible's own -q idempotency check)" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), <<-MAKEFILE)
      all: output.txt

      output.txt:
      \ttouch output.txt
      MAKEFILE
    File.delete(File.join(PluginSpecHelper.tmp_path("make"), "output.txt")) if File.exists?(File.join(PluginSpecHelper.tmp_path("make"), "output.txt"))

    result = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make")})
    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(PluginSpecHelper.tmp_path("make"), "output.txt")).must_equal(true)

    result2 = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make")})
    result2["changed"].as_bool.must_equal(false)
  end

  it "runs a specific target: " do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), <<-MAKEFILE)
      all: output.txt

      output.txt:
      \ttouch output.txt

      clean:
      \trm -f output.txt
      MAKEFILE
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "output.txt"), "")

    result = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "clean"})
    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(PluginSpecHelper.tmp_path("make"), "output.txt")).must_equal(false)
  end

  it "requires chdir, with parameters.py's plural wording" do
    result = PluginSpecHelper.run("make", {} of String => String)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: chdir")
  end

  it "rejects target and targets together with Ansible's mutually-exclusive wording" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    result = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "all", "targets" => "all"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: target|targets")
  end

  it "carries the shlex-quoted base command in `command` (no msg), resolving gmake first like real get_bin_path" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), "all:\n\t@echo built-all\n")

    result = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "all"})

    result["changed"].as_bool.must_equal(true)
    result["msg"]?.must_be_nil
    result["command"].as_s.must_equal("/usr/bin/gmake all")
    result["stdout"].as_s.must_equal("built-all")
  end

  it "uses an explicit make: binary path verbatim" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), "all:\n\t@echo built-all\n")

    result = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "all", "make" => "/usr/bin/make"})

    result["command"].as_s.must_equal("/usr/bin/make all")
  end

  it "places jobs before the target and str()-formats params (bare key for None)" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), "all:\n\t@echo built-all\n")

    result = PluginSpecHelper.run("make", {
      "chdir"  => PluginSpecHelper.tmp_path("make"),
      "target" => "all",
      "jobs"   => "2",
      "params" => %({"NUM_THREADS": 4, "EXTRA": "y"}),
    })

    result["command"].as_s.must_equal("/usr/bin/gmake -j 2 all NUM_THREADS=4 EXTRA=y")
  end

  it "fails a failing target with check_rc's shape: the sanitized stderr as msg plus rc" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), "fail:\n\t@echo about-to-fail >&2\n\t@exit 2\n")

    result = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "fail"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["rc"].as_i.must_equal(2)
    result["msg"].as_s.must_include("about-to-fail")
    result["msg"].as_s.must_include("Error 2")
  end

  it "check mode reports changed from the -q probe with no msg" do
    Dir.mkdir_p(PluginSpecHelper.tmp_path("make"))
    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), "all:\n\t@echo built-all\n")

    stale = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "all", "_ansible_check_mode" => "true"})
    stale["changed"].as_bool.must_equal(true)
    stale["msg"]?.must_be_nil

    File.write(File.join(PluginSpecHelper.tmp_path("make"), "Makefile"), "out.txt:\n\t@echo rebuilt > out.txt\nall:\n\t@echo built-all\n")
    PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "out.txt"})
    fresh = PluginSpecHelper.run("make", {"chdir" => PluginSpecHelper.tmp_path("make"), "target" => "out.txt", "_ansible_check_mode" => "true"})
    fresh["changed"].as_bool.must_equal(false)
    fresh["msg"]?.must_be_nil
  end
end

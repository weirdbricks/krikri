require "../minitest_helper"

# Regression spec for issue #1610 (juju4.vivisect): pip.py's check-mode
# block resolves a non-requirement name (a VCS url, file path or archive)
# through _resolve_package_names, which reads the pip version from the
# interpreter that runs the module - `module.params['executable'] or
# sys.executable`. With `executable: pip3` that helper gets a pip binary
# it cannot run `-c` python code on, returns None, and pip.py
# dereferences it (`pip_dep.split('==')`), failing the task with
# "'NoneType' object has no attribute 'split'" after its retries. krikri
# read the pip version with `pip show pip` instead, so the same task
# reported changed and the rest of the play ran, with a different exit
# code. Verified against real ansible-core 2.21.6.
describe "pip: check-mode resolution asks the executable for its pip version" do
  it "fails like pip.py when executable: cannot report its own pip version" do
    with_check_mode_pip_executable do |script|
      result = PluginSpecHelper.run("pip", {
        "name"                => "https://github.com/vivisect/vivisect/zipball/master",
        "state"               => "present",
        "executable"          => script,
        "_ansible_check_mode" => "true",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Task failed: Module failed: 'NoneType' object has no attribute 'split'")
    end
  end

  it "does not probe the executable for a parseable requirement" do
    with_check_mode_pip_executable do |script|
      result = PluginSpecHelper.run("pip", {
        "name"                => "requests",
        "state"               => "present",
        "executable"          => script,
        "_ansible_check_mode" => "true",
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      result["changed"].as_bool.must_equal(true)
    end
  end
end

# A fake pip executable: `-c` fails the way a real pip refuses python
# flags, `list --format=freeze` succeeds with nothing installed, `show
# pip` reports a modern pip, and a dry-run install fails so the caller
# keeps its unresolved probes.
private def write_check_mode_fake_pip(script : String) : Nil
  File.write(script, <<-SH
    #!/bin/sh
    if [ "$1" = "-c" ]; then exit 2; fi
    if [ "$1" = "list" ]; then echo "nothing-installed==0.0.0"; exit 0; fi
    if [ "$1" = "show" ]; then echo "Name: pip"; echo "Version: 25.1.1"; exit 0; fi
    if [ "$1" = "install" ]; then echo "dry-run probe" >&2; exit 1; fi
    exit 0
    SH
  )
  File.chmod(script, 0o755)
end

private def with_check_mode_pip_executable(&)
  dir = PluginSpecHelper.tmp_path("pip-check-mode-executable")
  Dir.mkdir(dir)
  script = File.join(dir, "fakepip")
  write_check_mode_fake_pip(script)
  begin
    yield script
  ensure
    File.delete(script) if File.exists?(script)
    Dir.delete(dir) if Dir.exists?(dir)
  end
end

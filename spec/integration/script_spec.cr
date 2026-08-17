require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def sc_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "script plugin" do
  it "executes a script and captures its stdout" do
    path = sc_path("script_echo.sh")
    File.write(path, "#!/bin/sh\necho hello-from-script\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path})

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_true
    result["stdout"].as_s.should eq("hello-from-script")
    result["rc"].as_i.should eq(0)
  end

  it "passes trailing arguments through to the script" do
    path = sc_path("script_args.sh")
    File.write(path, "#!/bin/sh\necho \"got: $1 $2\"\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => "#{path} one two"})

    result["stdout"].as_s.should eq("got: one two")
  end

  it "reports failed: true for a non-zero exit code" do
    path = sc_path("script_fail.sh")
    File.write(path, "#!/bin/sh\nexit 3\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path})

    result["failed"].as_bool.should be_true
    result["rc"].as_i.should eq(3)
  end

  it "skips when creates: already exists" do
    path = sc_path("script_creates.sh")
    File.write(path, "#!/bin/sh\ntouch #{sc_path("script_creates_marker")}\n")
    File.chmod(path, 0o755)
    marker = sc_path("script_creates_marker")
    File.write(marker, "already here")

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => marker})

    result["changed"].as_bool.should be_false
    File.delete(marker)
  end

  it "runs with executable: as an explicit interpreter" do
    path = sc_path("script_interp.py")
    File.write(path, "print('via-interpreter')\n")

    result = PluginSpecHelper.run("script", {"cmd" => path, "executable" => "/usr/bin/env python3"})

    result["stdout"].as_s.should eq("via-interpreter")
  end

  it "fails clearly when the script path doesn't exist" do
    result = PluginSpecHelper.run("script", {"cmd" => sc_path("does-not-exist.sh")})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("does not exist")
  end
end

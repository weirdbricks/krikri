require "../minitest_helper"
require "file_utils"

# mysql_db.py applies `chdir:` (argument_spec type='path') with
# os.chdir right after reading its parameters - before the state/target
# checks, before the check-mode branch and before mysql_connect - and
# embeds Python's own OSError text in the fail_json message. Found by
# krikri-playbook-generator (issue #1621): `chdir: 21` failed on real
# ansible with "Cannot change the current directory to 21: [Errno 2] No
# such file or directory: '21'" while krikri ignored the parameter and
# went on to connect. The type='path' coercion happens BEFORE the falsy
# test, so a native scalar is stringified through Python's str()
# (`chdir: false` -> "False", `chdir: 0` -> "0") and only an empty value
# skips the chdir.
describe "mysql_db chdir" do
  it "fails a non-existent integer chdir before attempting a connection" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"              => "krikri_probe",
      "chdir"             => Krikri::NON_STRING_PARAM_PREFIX + "21",
      "login_user"        => "root",
      "login_unix_socket" => "/nonexistent/krikri-issue-1621.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Cannot change the current directory to 21: [Errno 2] No such file or directory: '21'")
  end

  it "stringifies a native non-string chdir through Python's str()" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"              => "krikri_probe",
      "chdir"             => Krikri::NON_STRING_PARAM_PREFIX + "false",
      "login_user"        => "root",
      "login_unix_socket" => "/nonexistent/krikri-issue-1621.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Cannot change the current directory to False: [Errno 2] No such file or directory: 'False'")
  end

  it "reports a regular file as 'Not a directory'" do
    file = PluginSpecHelper.tmp_path("not-a-dir")
    File.write(file, "")

    result = PluginSpecHelper.run("mysql_db", {
      "name"              => "krikri_probe",
      "chdir"             => file,
      "login_user"        => "root",
      "login_unix_socket" => "/nonexistent/krikri-issue-1621.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Cannot change the current directory to #{file}: [Errno 20] Not a directory: '#{file}'")
  end

  it "fails a bad chdir even when dump has no target" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"  => "krikri_probe",
      "state" => "dump",
      "chdir" => "21",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Cannot change the current directory to 21:")
  end

  it "skips an empty chdir" do
    result = PluginSpecHelper.run("mysql_db", {
      "name"              => "krikri_probe",
      "chdir"             => "",
      "login_user"        => "root",
      "login_unix_socket" => "/nonexistent/krikri-issue-1621.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.wont_include("Cannot change the current directory")
  end

  it "runs dump from the chdir, so a relative target lands under it" do
    shim_dir = PluginSpecHelper.tmp_path("shims")
    Dir.mkdir_p(shim_dir)
    shim = File.join(shim_dir, "mysqldump")
    File.write(shim, "#!/bin/sh\necho SHIM-OK\n")
    File.chmod(shim, 0o755)

    work_dir = PluginSpecHelper.tmp_path("run")
    Dir.mkdir_p(work_dir)
    task_dir = PluginSpecHelper.tmp_path("taskdir")
    Dir.mkdir_p(task_dir)

    result = PluginSpecHelper.run("mysql_db", {
      "name"   => "krikri_probe",
      "state"  => "dump",
      "target" => "out.sql",
      "chdir"  => task_dir,
    }, chdir: work_dir, env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]?}"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(task_dir, "out.sql")).must_equal(true)
    File.exists?(File.join(work_dir, "out.sql")).must_equal(false)
  end
end

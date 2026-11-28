require "../minitest_helper"

# mysql_db.py's connection-failure wrapper (issue #1962): its except clause
# branches on os.path.exists(config_file) and, when the option file is not
# there, names the file it looked for instead of login_user/login_password.
# The engine used to print the generic "Could not connect to the MySQL
# server:" shape with no exception tail at all.
describe "mysql_db plugin connection failure" do
  it "names the option file it looked for when config_file does not exist" do
    missing = File.join(PluginSpecHelper.tmp_path("mysql-db-missing-cnf"), "no-such.cnf")
    Dir.mkdir_p(File.dirname(missing))

    result = PluginSpecHelper.run("mysql_db", {
      "name"              => "krikri_probe",
      "config_file"       => missing,
      "login_unix_socket" => "/run/krikri-no-such-mysql.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(
      /\Aunable to find #{Regex.escape(missing)}\. Exception message: \(\d{4}, "Can't connect to (local )?MySQL server/)
  end

  it "blames the credentials, with the driver's exception repr, when the option file exists" do
    path = File.join(PluginSpecHelper.tmp_path("mysql-db-existing-cnf"), "my.cnf")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "")

    result = PluginSpecHelper.run("mysql_db", {
      "name"              => "krikri_probe",
      "config_file"       => path,
      "login_unix_socket" => "/run/krikri-no-such-mysql.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(
      /\Aunable to connect to database, check login_user and login_password are correct or #{Regex.escape(path)} has the credentials\. Exception message: \(\d{4}, "Can't connect to (local )?MySQL server/)
  end
end

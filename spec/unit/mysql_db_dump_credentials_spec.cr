require "../spec_helper"
require "file_utils"

# Regression spec for the credential-staging wiring in mysql_db's
# dump/import path: when login_password is given (and the user did not
# supply their own config_file), the password must reach mysqldump/mysql
# via a staged 0600 --defaults-extra-file, NOT via --password= on argv,
# and the staged file must be gone afterwards. A previous security pass
# staged the file but never added the --defaults-extra-file= flag to the
# tool's command line, so dump/import silently ran with no credentials
# at all.
#
# No MySQL server is involved: mysqldump/mysql are shimmed on PATH to
# capture their argv and whatever the staged defaults file contained,
# which is exactly what the server would have authenticated against.
private def with_shims(&)
  dir = File.tempname(Dir.tempdir, "krikri-mysql-db-spec")
  Dir.mkdir(dir)
  shim_dir = File.join(dir, "shims")
  Dir.mkdir(shim_dir)
  capture_dir = File.join(dir, "capture")
  Dir.mkdir(capture_dir)

  shim_body = <<-'SH'
    #!/bin/bash
    printf '%s\n' "$@" > "$CAPTURE_DIR/argv"
    for arg in "$@"; do
      case "$arg" in
        --defaults-extra-file=*) cp "${arg#--defaults-extra-file=}" "$CAPTURE_DIR/defaults_file" 2>/dev/null ;;
      esac
    done
    echo "SHIM-OK"
    exit 0
    SH
  %w[mysqldump mysql].each do |name|
    path = File.join(shim_dir, name)
    File.write(path, shim_body)
    File.chmod(path, 0o755)
  end

  old_path = ENV["PATH"]?
  old_capture = ENV["CAPTURE_DIR"]?
  ENV["CAPTURE_DIR"] = capture_dir
  ENV["PATH"] = "#{shim_dir}:#{old_path}"
  begin
    yield capture_dir
  ensure
    old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    old_capture ? (ENV["CAPTURE_DIR"] = old_capture) : (ENV.delete("CAPTURE_DIR"))
    FileUtils.rm_rf(dir)
  end
end

describe "mysql_db dump/import credential staging" do
  it "dump passes login_password via the staged --defaults-extra-file, never argv" do
    with_shims do |capture_dir|
      target = File.tempname(Dir.tempdir, "krikri-dump.sql")
      begin
        result = PluginSpecHelper.run("mysql_db", {
          "name"           => "mydb",
          "state"          => "dump",
          "target"         => target,
          "login_user"     => "dbadmin",
          "login_password" => "s3cret'pw!",
        })

        result["changed"].as_bool.should be_true
        argv = File.read(File.join(capture_dir, "argv"))
        argv.should contain("--defaults-extra-file=")
        argv.should_not contain("--password=")
        argv.should_not contain("s3cret")

        staged_path = argv.split('\n').find!(&.starts_with?("--defaults-extra-file="))
        staged_path = staged_path.lchop("--defaults-extra-file=")
        File.read(File.join(capture_dir, "defaults_file")).should eq(
          "[client]\nuser=dbadmin\npassword=s3cret'pw!\n")
        File.exists?(staged_path).should be_false
      ensure
        File.delete?(target)
      end
    end
  end

  it "import passes login_password via the staged --defaults-extra-file, never argv" do
    with_shims do |capture_dir|
      target = File.tempname(Dir.tempdir, "krikri-import.sql")
      File.write(target, "CREATE TABLE t (id int);")
      begin
        result = PluginSpecHelper.run("mysql_db", {
          "name"           => "mydb",
          "state"          => "import",
          "target"         => target,
          "login_user"     => "dbadmin",
          "login_password" => "s3cret'pw!",
        })

        result["changed"].as_bool.should be_true
        argv = File.read(File.join(capture_dir, "argv"))
        argv.should contain("--defaults-extra-file=")
        argv.should_not contain("--password=")
        argv.should_not contain("s3cret")
        File.read(File.join(capture_dir, "defaults_file")).should eq(
          "[client]\nuser=dbadmin\npassword=s3cret'pw!\n")
      ensure
        File.delete?(target)
      end
    end
  end

  it "keeps the documented config_file behavior (user's own defaults file + --password= on argv)" do
    with_shims do |capture_dir|
      target = File.tempname(Dir.tempdir, "krikri-dump.sql")
      begin
        result = PluginSpecHelper.run("mysql_db", {
          "name"           => "mydb",
          "state"          => "dump",
          "target"         => target,
          "config_file"    => "/etc/my.cnf",
          "login_user"     => "dbadmin",
          "login_password" => "s3cret'pw!",
        })

        result["changed"].as_bool.should be_true
        argv = File.read(File.join(capture_dir, "argv"))
        argv.should contain("--defaults-extra-file=/etc/my.cnf")
        argv.should contain("--password=s3cret'pw!")
      ensure
        File.delete?(target)
      end
    end
  end
end

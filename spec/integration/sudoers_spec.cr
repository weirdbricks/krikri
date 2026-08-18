require "../spec_helper"

# All of these specs write into a throwaway sudoers_path: directory in
# spec/tmp rather than the real /etc/sudoers.d - fully safe to run
# repeatedly and without root.

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "sudoers plugin" do
  it "writes a rule file for a user with default options" do
    dir = tmp_path("sudoers-basic")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result["changed"].as_bool.should be_true
    file = File.join(dir, "allow-backup")
    File.exists?(file).should be_true
    File.read(file).should eq("backup ALL=NOPASSWD: /usr/local/bin/backup\n")
    (File.info(file).permissions.value & 0o777).should eq(0o440)
  end

  it "is idempotent on a second identical run" do
    dir = tmp_path("sudoers-idempotent")
    `rm -rf #{dir}`
    PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result["changed"].as_bool.should be_false
  end

  it "supports group:, host:, runas:, and multiple commands" do
    dir = tmp_path("sudoers-full")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {
      "name"         => "alice-service",
      "group"        => "sudoers-fullgrp",
      "host"         => "webserver",
      "runas"        => "root",
      "commands"     => %(["/bin/systemctl restart my-service", "/bin/systemctl reload my-service"]),
      "nopassword"   => "false",
      "setenv"       => "true",
      "noexec"       => "true",
      "sudoers_path" => dir,
      "validation"   => "absent",
    })

    result["changed"].as_bool.should be_true
    content = File.read(File.join(dir, "alice-service"))
    content.should eq("%sudoers-fullgrp webserver=(root)NOEXEC:SETENV: /bin/systemctl restart my-service, /bin/systemctl reload my-service\n")
  end

  it "removes a rule file with state: absent" do
    dir = tmp_path("sudoers-absent")
    `rm -rf #{dir}`
    PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "state" => "absent", "sudoers_path" => dir})

    result["changed"].as_bool.should be_true
    File.exists?(File.join(dir, "allow-backup")).should be_false
  end

  it "reports no change when removing an already-absent rule" do
    dir = tmp_path("sudoers-absent-noop")
    `rm -rf #{dir}`
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "state" => "absent", "sudoers_path" => dir})

    result["changed"].as_bool.should be_false
  end

  it "does not write in check mode" do
    dir = tmp_path("sudoers-check-mode")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(File.join(dir, "allow-backup")).should be_false
  end

  it "fails when neither user nor group is given" do
    dir = tmp_path("sudoers-missing-owner")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result["failed"].as_bool.should be_true
  end

  it "validates the generated rule via visudo when validation: detect (the default)" do
    dir = tmp_path("sudoers-validate")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir})

    result["changed"].as_bool.should be_true
    File.exists?(File.join(dir, "allow-backup")).should be_true
  end

  it "fails validation for a rule that produces invalid sudoers syntax" do
    dir = tmp_path("sudoers-validate-fail")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "bad-rule", "user" => "back\nup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir})

    result["failed"].as_bool.should be_true
    File.exists?(File.join(dir, "bad-rule")).should be_false
  end

  it "fails when commands is missing for state: present" do
    dir = tmp_path("sudoers-missing-commands")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "sudoers_path" => dir, "validation" => "absent"})

    result["failed"].as_bool.should be_true
  end
end

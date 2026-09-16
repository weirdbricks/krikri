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
    Dir.mkdir_p(dir)

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
    Dir.mkdir_p(dir)
    PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent"})

    result["changed"].as_bool.should be_false
  end

  it "supports group:, host:, runas:, and multiple commands" do
    dir = tmp_path("sudoers-full")
    `rm -rf #{dir}`
    Dir.mkdir_p(dir)

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
    Dir.mkdir_p(dir)
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

    result = PluginSpecHelper.run("sudoers", {"name" => "allow-backup", "user" => "backup", "commands" => "/usr/local/bin/backup", "sudoers_path" => dir, "validation" => "absent", "_ansible_check_mode" => "true"})

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
    Dir.mkdir_p(dir)

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

  # Real AnsibleModule setup surface (podman-diff sudoers_edge_cases):
  # mutually exclusive -> required -> types -> choices -> required_if
  # -> unsupported, all before any plugin logic runs.

  it "fails when both user and group are given (mutually exclusive, even for state: absent)" do
    dir = tmp_path("sudoers-mutually-exclusive")
    `rm -rf #{dir}`
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "group" => "testg", "commands" => "ALL", "sudoers_path" => dir, "validation" => "absent"})

    result["failed"].as_bool.should be_true
    File.exists?(File.join(dir, "rule")).should be_false

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "state" => "absent", "user" => "testu", "group" => "testg", "sudoers_path" => dir})

    result["failed"].as_bool.should be_true
  end

  it "fails on invalid state/validation choices" do
    dir = tmp_path("sudoers-choices")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "ALL", "state" => "bogus", "sudoers_path" => dir, "validation" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of state must be one of: present, absent, got: bogus")

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "ALL", "validation" => "bogus", "sudoers_path" => dir})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of validation must be one of: absent, detect, required, got: bogus")
  end

  it "fails on unsupported parameters in the real UnsupportedError format" do
    dir = tmp_path("sudoers-unsupported")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "ALL", "bogus" => "1", "sudoers_path" => dir, "validation" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.sudoers) module: bogus. Supported parameters include: commands, defaults, group, host, name, noexec, nopassword, runas, setenv, state, sudoers_path, user, validation.")
  end

  it "fails the write when sudoers_path does not exist (no dir auto-creation)" do
    dir = tmp_path("sudoers-missing-dir/nope")
    `rm -rf #{dir}`

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "ALL", "sudoers_path" => dir, "validation" => "absent"})

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    File.exists?(dir).should be_false
  end

  it "accepts an empty commands list (required_if only fails a MISSING key) and writes the trailing-space content" do
    dir = tmp_path("sudoers-empty-commands")
    `rm -rf #{dir}`
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "[]", "sudoers_path" => dir, "validation" => "absent"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dir, "rule")).should eq("testu ALL=NOPASSWD: \n")
  end

  it "comma-splits a string commands value without stripping elements" do
    dir = tmp_path("sudoers-no-strip")
    `rm -rf #{dir}`
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "cmd1, cmd2", "sudoers_path" => dir, "validation" => "absent"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dir, "rule")).should eq("testu ALL=NOPASSWD: cmd1,  cmd2\n")
  end

  it "writes Defaults directives scoped to the owner before the rule (real 13.1.0 defaults param)" do
    dir = tmp_path("sudoers-defaults")
    `rm -rf #{dir}`
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("sudoers", {"name" => "rule", "user" => "testu", "commands" => "ALL", "defaults" => %(["!targetpw"]), "sudoers_path" => dir, "validation" => "absent"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dir, "rule")).should eq("Defaults:testu !targetpw\ntestu ALL=NOPASSWD: ALL\n")
  end
end

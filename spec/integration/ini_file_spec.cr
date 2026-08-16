require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "ini_file plugin" do
  it "creates a new file with a section and option" do
    path = tmp_path("ini_file-create")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.should be_true
    # Real Ansible's own ini_file module force-seeds a single leading
    # blank line whenever the starting file is empty/nonexistent (`if not
    # ini_lines: ini_lines.append("\n")`) before any section/option
    # insertion - a brand-new config always gets exactly one blank line
    # before its first "[section]" header. Found benchmarking
    # robertdebock.python_pip's own fresh /etc/pip.conf write.
    File.read(path).should eq("\n[mysqld]\nport = 3306\n")
  end

  it "uncomments and replaces an existing commented-out option line in place, matching real Ansible's modify_inactive_option default" do
    path = tmp_path("ini_file-uncomment-option")
    File.write(path, "[Journal]\n#Storage=auto\n#LineMax=48K\n#ReadKMsg=yes\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Journal", "option" => "LineMax", "value" => "48k"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("[Journal]\n#Storage=auto\nLineMax = 48k\n#ReadKMsg=yes\n")
  end

  it "adds an option to an existing section without disturbing others" do
    path = tmp_path("ini_file-add-option")
    File.write(path, "[mysqld]\nbind-address = 127.0.0.1\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("bind-address = 127.0.0.1")
    content.should contain("port = 3306")
  end

  it "updates an existing option's value" do
    path = tmp_path("ini_file-update")
    File.write(path, "[mysqld]\nport = 3305\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("[mysqld]\nport = 3306\n")
  end

  it "is idempotent when the value is already set" do
    path = tmp_path("ini_file-idempotent")
    File.write(path, "[mysqld]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.should be_false
  end

  it "creates a missing section when create is not disabled" do
    path = tmp_path("ini_file-new-section")
    File.write(path, "[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain("[client]")
    content.should contain("[mysqld]")
  end

  it "removes an option when state=absent" do
    path = tmp_path("ini_file-remove-option")
    File.write(path, "[mysqld]\nport = 3306\nbind-address = 127.0.0.1\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "state" => "absent"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should_not contain("port")
    content.should contain("bind-address = 127.0.0.1")
  end

  it "removes an entire section when state=absent with no option" do
    path = tmp_path("ini_file-remove-section")
    File.write(path, "[mysqld]\nport = 3306\n[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "state" => "absent"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should_not contain("[mysqld]")
    content.should contain("[client]")
  end

  it "collapses duplicate options to one when exclusive (the default)" do
    path = tmp_path("ini_file-exclusive")
    File.write(path, "[mysqld]\nport = 3305\nport = 3307\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("[mysqld]\nport = 3306\n")
  end

  it "supports no_extra_spaces" do
    path = tmp_path("ini_file-no-extra-spaces")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "no_extra_spaces" => "true"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("\n[mysqld]\nport=3306\n")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("ini_file-check-mode")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(path).should be_false
  end

  it "fails with a clear message when path is missing" do
    result = PluginSpecHelper.run("ini_file", {"section" => "mysqld", "option" => "port", "value" => "3306"})

    result["failed"].as_bool.should be_true
  end

  it "fails when section does not exist and create is false" do
    path = tmp_path("ini_file-no-create")
    File.write(path, "[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "create" => "false"})

    result["failed"].as_bool.should be_true
  end
end

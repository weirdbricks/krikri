require "../minitest_helper"

describe "ini_file plugin" do
  it "creates a new file with a section and option" do
    path = PluginSpecHelper.tmp_path("ini_file-create")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.must_equal(true)
    # Real Ansible's own ini_file module force-seeds a single leading
    # blank line whenever the starting file is empty/nonexistent (`if not
    # ini_lines: ini_lines.append("\n")`) before any section/option
    # insertion - a brand-new config always gets exactly one blank line
    # before its first "[section]" header. Found benchmarking
    # robertdebock.python_pip's own fresh /etc/pip.conf write.
    File.read(path).must_equal("\n[mysqld]\nport = 3306\n")
  end

  it "appends a new section header directly after existing content, with no blank-line separator" do
    # Real do_ini appends "[section]" straight onto the lines list; the
    # only blank line real ever produces is the empty-file seed. Adding
    # another separator here put a spurious blank line between the
    # previous section's last option and every appended header (caught
    # by the podman-diff harness's byte-for-byte `cat` of the file).
    path = PluginSpecHelper.tmp_path("ini_file-append-section")
    File.write(path, "[alpha]\nkey1 = one\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "beta", "option" => "opt", "value" => "x"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("[alpha]\nkey1 = one\n[beta]\nopt = x\n")
  end

  it "uncomments and replaces an existing commented-out option line in place, matching real Ansible's modify_inactive_option default" do
    path = PluginSpecHelper.tmp_path("ini_file-uncomment-option")
    File.write(path, "[Journal]\n#Storage=auto\n#LineMax=48K\n#ReadKMsg=yes\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Journal", "option" => "LineMax", "value" => "48k"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("[Journal]\n#Storage=auto\nLineMax = 48k\n#ReadKMsg=yes\n")
  end

  it "adds an option to an existing section without disturbing others" do
    path = PluginSpecHelper.tmp_path("ini_file-add-option")
    File.write(path, "[mysqld]\nbind-address = 127.0.0.1\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("bind-address = 127.0.0.1")
    content.must_include("port = 3306")
  end

  it "updates an existing option's value" do
    path = PluginSpecHelper.tmp_path("ini_file-update")
    File.write(path, "[mysqld]\nport = 3305\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("[mysqld]\nport = 3306\n")
  end

  it "is idempotent when the value is already set" do
    path = PluginSpecHelper.tmp_path("ini_file-idempotent")
    File.write(path, "[mysqld]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.must_equal(false)
  end

  it "creates a missing section when create is not disabled" do
    path = PluginSpecHelper.tmp_path("ini_file-new-section")
    File.write(path, "[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("[client]")
    content.must_include("[mysqld]")
  end

  it "does not remove a commented-out option line with state=absent, matching real Ansible's match_active_opt" do
    path = PluginSpecHelper.tmp_path("ini_file-absent-commented")
    File.write(path, "[Journal]\n#Storage=auto\n#Compress=yes\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Journal", "option" => "Storage", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal("[Journal]\n#Storage=auto\n#Compress=yes\n")
  end

  it "removes an option when state=absent" do
    path = PluginSpecHelper.tmp_path("ini_file-remove-option")
    File.write(path, "[mysqld]\nport = 3306\nbind-address = 127.0.0.1\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.wont_include("port")
    content.must_include("bind-address = 127.0.0.1")
  end

  it "removes an entire section when state=absent with no option" do
    path = PluginSpecHelper.tmp_path("ini_file-remove-section")
    File.write(path, "[mysqld]\nport = 3306\n[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.wont_include("[mysqld]")
    content.must_include("[client]")
  end

  it "collapses duplicate options to one when exclusive (the default)" do
    path = PluginSpecHelper.tmp_path("ini_file-exclusive")
    File.write(path, "[mysqld]\nport = 3305\nport = 3307\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("[mysqld]\nport = 3306\n")
  end

  # `values:` arrives JSON-encoded (parse_module_params encodes the list
  # for ini_file the way it already does for assert.that/mysql_query
  # argv), so the specs pass the same wire string the parser produces.
  it "inserts every values: list entry in order, including an empty string as a real value" do
    # round900703 RedHatOfficial.rhel9_cui's ExecStart task, verified
    # byte-for-byte against real community.general.ini_file 12.5.0
    # (ansible-core 2.19.11): with allow_no_value at its false default
    # the empty string is a REAL value producing a bare `ExecStart = `
    # line, and both entries land in original list order.
    path = PluginSpecHelper.tmp_path("ini_file-values-list")
    File.write(path, "[Service]\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Service", "option" => "ExecStart",
                                               "values" => %(["", "-/usr/lib/systemd/systemd-sulogin-shell rescue"])})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("option added")
    File.read(path).must_equal("[Service]\nExecStart = \nExecStart = -/usr/lib/systemd/systemd-sulogin-shell rescue\n")
  end

  it "is idempotent when every values: list entry is already present" do
    path = PluginSpecHelper.tmp_path("ini_file-values-idempotent")
    File.write(path, "[Service]\nExecStart = \nExecStart = -/usr/lib/systemd/systemd-sulogin-shell rescue\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Service", "option" => "ExecStart",
                                               "values" => %(["", "-/usr/lib/systemd/systemd-sulogin-shell rescue"])})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal("[Service]\nExecStart = \nExecStart = -/usr/lib/systemd/systemd-sulogin-shell rescue\n")
  end

  it "claims existing correctly-valued lines, overwrites a stale line in place, and inserts the rest before trailing blank lines (real do_ini's exclusive algorithm)" do
    # Verified byte-for-byte against real community.general.ini_file
    # 12.5.0: the stale `ExecStart=foo` line absorbs the first unplaced
    # value in place, and the remaining value is inserted after the
    # section's last non-blank/non-comment line - NOT after the blank
    # line that separates the section from the next header.
    path = PluginSpecHelper.tmp_path("ini_file-values-stale")
    File.write(path, "[Service]\nExecStart=foo\nType=oneshot\n\n[Other]\nx=1\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Service", "option" => "ExecStart",
                                               "values" => %(["", "-/usr/lib/systemd/systemd-sulogin-shell rescue"])})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("[Service]\nExecStart = \nType=oneshot\nExecStart = -/usr/lib/systemd/systemd-sulogin-shell rescue\n\n[Other]\nx=1\n")
  end

  it "fails with real Ansible's mutual-exclusion error when value and values are both given" do
    path = PluginSpecHelper.tmp_path("ini_file-values-exclusive-params")
    File.write(path, "[Service]\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "Service", "option" => "ExecStart",
                                               "value" => "x", "values" => %(["y"])})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: value|values")
    File.read(path).must_equal("[Service]\n")
  end

  it "supports no_extra_spaces" do
    path = PluginSpecHelper.tmp_path("ini_file-no-extra-spaces")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "no_extra_spaces" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("\n[mysqld]\nport=3306\n")
  end

  it "does not write to disk in check mode" do
    path = PluginSpecHelper.tmp_path("ini_file-check-mode")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(false)
  end

  it "fails with a clear message when path is missing" do
    result = PluginSpecHelper.run("ini_file", {"section" => "mysqld", "option" => "port", "value" => "3306"})

    result["failed"].as_bool.must_equal(true)
  end

  it "fails when section does not exist and create is false" do
    path = PluginSpecHelper.tmp_path("ini_file-no-create")
    File.write(path, "[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "create" => "false"})

    result["failed"].as_bool.must_equal(true)
  end

  # Real community.general ini_file's per-branch msg strings and
  # always-present diff dict (live-verified against ansible-core
  # 2.19.11: "section and option added" / "option added" / "option
  # changed" / "section removed" / "OK", and a diff dict keyed with
  # "<path> (content)" headers whose before/after content is only
  # filled in --diff mode).
  describe "msg and diff shape (real ansible's field set)" do
    it "says 'section and option added' when both are newly created" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-new")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "timeout", "value" => "30"})

      result["msg"].as_s.must_equal("section and option added")
    end

    it "says 'option added' when the option is new in an existing section" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-added")
      File.write(path, "[core]\nold = 1\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "added", "value" => "2"})

      result["msg"].as_s.must_equal("option added")
    end

    it "says 'option changed' when an existing option is rewritten" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-changed")
      File.write(path, "[core]\nold = 1\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "old", "value" => "2"})

      result["msg"].as_s.must_equal("option changed")
    end

    it "says 'option changed' for a state=absent removal" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-removed")
      File.write(path, "[core]\nold = 1\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "old", "state" => "absent"})

      result["msg"].as_s.must_equal("option changed")
    end

    it "says 'section removed' when state=absent drops the whole section" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-section-removed")
      File.write(path, "[core]\nold = 1\n[extra]\nmore = 2\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "extra", "state" => "absent"})

      result["msg"].as_s.must_equal("section removed")
    end

    it "says 'OK' when nothing changed" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-ok")
      File.write(path, "[core]\nold = 1\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "old", "value" => "1"})

      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("OK")
    end

    it "always carries a diff dict with '<path> (content)' headers, empty content outside --diff" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-diff")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "timeout", "value" => "30"})

      diff = result["diff"].as_h
      diff["before_header"].as_s.must_equal("#{path} (content)")
      diff["after_header"].as_s.must_equal("#{path} (content)")
      diff["before"].as_s.must_be_empty
      diff["after"].as_s.must_be_empty
    end

    it "omits backup_file when no backup was made" do
      path = PluginSpecHelper.tmp_path("ini_file-msg-no-backup")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "core", "option" => "timeout", "value" => "30"})

      result["backup_file"]?.must_be_nil
    end
  end
end

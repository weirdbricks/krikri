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

  # Corrected against real community.general.ini_file 12.5.0 (kpg32
  # seed 32): `create` gates the FILE only, never a section header -
  # do_ini appends a missing `[section]` and its option regardless, so
  # this used-to-fail case is a plain "section and option added" in
  # real. The replacement spec for the still-real failure (a missing
  # FILE) lives in the "create:false against a missing section" block
  # at the end of this file.
  it "appends a missing section under create: false, as real's do_ini does" do
    path = PluginSpecHelper.tmp_path("ini_file-no-create")
    File.write(path, "[client]\nport = 3306\n")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "mysqld", "option" => "port", "value" => "3306", "create" => "false"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("section and option added")
    File.read(path).must_equal("[client]\nport = 3306\n[mysqld]\nport = 3306\n")
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

  # Real community.general.ini_file 12.5.0 main()'s own guard (captured
  # live against ansible-core 2.19.11): `if state == 'present' and not
  # allow_no_value and value is None and not values` - no option
  # requirement, an explicitly empty values list fails identically, and
  # the old "Value must be set when state=present and option is defined"
  # wording is gone.
  describe "value-required guard (real wording)" do
    it "fails with real's exact message when no value/values is given" do
      path = PluginSpecHelper.tmp_path("ini_file-value-required")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec", "option" => "opt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Parameter 'value(s)' must be defined if state=present and allow_no_value=False.")
      File.exists?(path).must_equal(false)
    end

    it "fails identically without an option at all" do
      path = PluginSpecHelper.tmp_path("ini_file-value-required-no-option")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {"path" => path})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Parameter 'value(s)' must be defined if state=present and allow_no_value=False.")
    end

    it "fails identically for an explicitly empty values list" do
      path = PluginSpecHelper.tmp_path("ini_file-value-required-empty-list")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "option" => "opt", "values" => "[]"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Parameter 'value(s)' must be defined if state=present and allow_no_value=False.")
    end

    it "does not fail for state=absent" do
      path = PluginSpecHelper.tmp_path("ini_file-absent-no-value")
      File.write(path, "[sec]\nopt = 1\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec", "option" => "opt", "state" => "absent"})

      result["msg"].as_s.must_equal("option changed")
    end
  end

  # allow_no_value=True with no values: real do_ini rewrites the FIRST
  # matching line (match_opt matches bare `option` lines too) to a bare
  # `option` line, or inserts one at the end of the section when absent -
  # captured live against ansible-core 2.19.11 ("changed" on a fresh
  # file and on `opt1 = x`, ok on a re-run and on an existing bare line).
  describe "allow_no_value with no values" do
    it "creates a bare option line in a fresh file" do
      path = PluginSpecHelper.tmp_path("ini_file-anv-fresh")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {"path" => path, "option" => "opt1", "allow_no_value" => "true"})

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("option added")
      # Byte-identical to real 2.19.11 (xxd-verified): the option line,
      # then the seed blank line's own newline as trailing content.
      File.read(path).must_equal("opt1\n\n")
    end

    it "is idempotent on an existing bare option line" do
      path = PluginSpecHelper.tmp_path("ini_file-anv-idempotent")
      File.write(path, "opt1\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "option" => "opt1", "allow_no_value" => "true"})

      result["changed"].as_bool.must_equal(false)
      File.read(path).must_equal("opt1\n")
    end

    it "rewrites an existing valued option line to a bare line" do
      path = PluginSpecHelper.tmp_path("ini_file-anv-rewrite")
      File.write(path, "opt1 = x\n")

      result = PluginSpecHelper.run("ini_file", {"path" => path, "option" => "opt1", "allow_no_value" => "true"})

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("option changed")
      File.read(path).must_equal("opt1\n")
    end
  end

  # kpg32 seed 32. Real ini_file's `create` gates the FILE only - it
  # never guards a section header, and do_ini appends a missing
  # `[section]` (with its option) either way, reporting "section and
  # option added". krikri used to fail the task with an invented
  # "Section [x] does not exist" message instead, so a create=false
  # task aimed at a not-yet-existing section hard-failed where real
  # succeeded.
  describe "create:false against a missing section (real behavior)" do
    it "appends the section and its option rather than failing" do
      path = PluginSpecHelper.tmp_path("ini_file-create-false-missing-section")
      File.write(path, "key = value\nkpg setting = on\n")

      result = PluginSpecHelper.run("ini_file", {
        "path" => path, "section" => "main", "option" => "kpg setting",
        "value" => "one", "create" => "false",
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("section and option added")
      File.read(path).must_equal("key = value\nkpg setting = on\n[main]\nkpg setting = one\n")
    end

    it "still fails with real's message when the FILE itself is missing" do
      path = PluginSpecHelper.tmp_path("ini_file-create-false-missing-file")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("ini_file", {
        "path" => path, "section" => "main", "option" => "kpg setting",
        "value" => "one", "create" => "false",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Destination #{path} does not exist!")
    end
  end

  # Real main()'s tail: `if not module.check_mode and os.path.exists(path):
  # changed = module.set_fs_attributes_if_different(file_args, changed)`.
  # It runs even when the content itself did not change, so a drifted
  # mode: IS a change - krikri used to tie apply_mode to the content
  # write, so a mode-only task on already-correct content reported
  # changed=false and left the mode alone.
  describe "file attributes on an otherwise-unchanged task" do
    it "applies mode: and reports the change even with no content change" do
      path = PluginSpecHelper.tmp_path("ini_file-mode-only")
      File.write(path, "[main]\nkey = value\n")
      File.chmod(path, 0o644)

      result = PluginSpecHelper.run("ini_file", {
        "path" => path, "section" => "main", "option" => "key",
        "value" => "value", "mode" => "0755",
      })

      result["changed"].as_bool.must_equal(true)
      File.read(path).must_equal("[main]\nkey = value\n")
      (File.info(path).permissions.value & 0o7777).must_equal(0o755)
    end

    it "reports no change when the mode already matches" do
      path = PluginSpecHelper.tmp_path("ini_file-mode-converged")
      File.write(path, "[main]\nkey = value\n")
      File.chmod(path, 0o644)

      result = PluginSpecHelper.run("ini_file", {
        "path" => path, "section" => "main", "option" => "key",
        "value" => "value", "mode" => "0644",
      })

      result["changed"].as_bool.must_equal(false)
      (File.info(path).permissions.value & 0o7777).must_equal(0o644)
    end
  end
end

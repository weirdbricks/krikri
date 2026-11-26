require "../minitest_helper"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "cronvar plugin" do
  it "creates the cron_file and adds the variable" do
    path = tmp_path("cronvar-create.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "admin@example.com",
      "cron_file" => path,
    })

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("MAILTO=admin@example.com")
  end

  it "resolves a relative cron_file: against /etc/cron.d, matching Ansible" do
    # Same proof shape as cron_spec's relative-path example. The
    # observable evidence of correct resolution depends on privilege:
    # unprivileged, a permission error at exactly the resolved path;
    # as root (CI's job container), the file is actually created there.
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "root",
      "cron_file" => "krikri-playbook-spec-relative",
    })

    resolved = "/etc/cron.d/krikri-playbook-spec-relative"
    if File::Info.writable?("/etc/cron.d")
      # failed is a JSON::Any - normalize via as_bool, and use be_falsey:
      # a JSON::Any(false) is not == false for the matcher, and a SUCCESS
      # result omits the failed key entirely (nil) - the path that runs
      # on a root CI container where /etc/cron.d is writable.
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.read(resolved).must_include("MAILTO=root")
      File.delete(resolved)
    else
      result["failed"]?.try(&.as_bool).must_equal(true)
      result["msg"].as_s.must_include(resolved)
    end
  end

  it "is idempotent on a second run with the same parameters" do
    path = tmp_path("cronvar-idempotent.txt")
    File.delete(path) if File.exists?(path)
    params = {
      "name"      => "MAILTO",
      "value"     => "root",
      "cron_file" => path,
    }

    first = PluginSpecHelper.run("cronvar", params)
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("cronvar", params)
    second["changed"].as_bool.must_equal(false)
  end

  it "updates the value in place when it changes" do
    path = tmp_path("cronvar-update.txt")
    PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "ops@example.com", "cron_file" => path})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("MAILTO=ops@example.com")
    content.wont_include("MAILTO=root")
  end

  it "is a no-op on an assignment that already holds the value, even with spaces around the = (Ansible module only rewrites when the parsed value differs)" do
    path = tmp_path("cronvar-spaces.txt")
    File.write(path, "MAILTO = root\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal("MAILTO = root\n")
  end

  it "removes the variable when state=absent" do
    path = tmp_path("cronvar-remove.txt")
    File.write(path, "MAILTO=root\nSHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.wont_include("MAILTO")
    content.must_include("SHELL=/bin/sh")
  end

  it "is a no-op removing a variable that isn't there" do
    path = tmp_path("cronvar-absent-noop.txt")
    File.write(path, "SHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "state" => "absent", "cron_file" => path})

    result["changed"].as_bool.must_equal(false)
  end

  it "leaves crontab schedule lines in the file untouched" do
    path = tmp_path("cronvar-schedule.txt")
    File.write(path, "SHELL=/bin/sh\n#Ansible: nightly backup\n0 2 * * * /bin/backup\n")

    PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    content = File.read(path)
    content.must_include("#Ansible: nightly backup")
    content.must_include("0 2 * * * /bin/backup")
    content.must_include("MAILTO=root")
  end

  it "returns the current variable list in vars" do
    path = tmp_path("cronvar-vars.txt")
    File.write(path, "SHELL=/bin/sh\n")

    result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

    result["vars"].as_a.map(&.as_s).must_equal(["MAILTO", "SHELL"])
  end

  it "supports insertafter positioning for a new variable" do
    path = tmp_path("cronvar-insertafter.txt")
    File.write(path, "SHELL=/bin/sh\nMAILTO=root\n")

    result = PluginSpecHelper.run("cronvar", {
      "name"        => "PATH",
      "value"       => "/usr/local/bin",
      "cron_file"   => path,
      "insertafter" => "SHELL",
    })

    result["changed"].as_bool.must_equal(true)
    lines = File.read(path).split("\n")
    lines.index("SHELL=/bin/sh").must_equal(0)
    lines.index("PATH=/usr/local/bin").must_equal(1)
  end

  # Real cronvar's AnsibleModule declares no supports_check_mode, so
  # basic.py's __init__ gate answers --check with a skip instead of ever
  # reaching the body (live-verified vs 2.21.6: registered skipped, msg,
  # failed, changed; the recap counts skipped). This plugin used to
  # compute the would-be result and report changed, which turned a
  # skipped task into an ok one.
  it "is skipped under check_mode, matching Ansible's own skip text" do
    path = tmp_path("cronvar-check-mode.txt")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("cronvar", {
      "name"                => "MAILTO",
      "value"               => "root",
      "cron_file"           => path,
      "_ansible_check_mode" => "true",
    })

    result["skipped"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["msg"].as_s.must_equal("remote module (community.general.cronvar) does not support check mode")
    result.as_h.keys.must_equal(["skipped", "msg"])
    File.exists?(path).must_equal(false)
  end

  # The gate sits after argument-spec validation but before
  # CronVar.__init__'s parent-directory guard and main()'s missing-value
  # check, so under --check both of those lose to the skip
  # (live-verified vs 2.21.6).
  it "skips under check_mode before the cron_file parent-directory guard" do
    result = PluginSpecHelper.run("cronvar", {
      "name"                => "MAILTO",
      "value"               => "admin@example.com",
      "cron_file"           => "/krikri/definitely/not/here/vars",
      "_ansible_check_mode" => "true",
    })

    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("remote module (community.general.cronvar) does not support check mode")
  end

  it "still fails a bogus state under check_mode, since argument-spec validation runs first" do
    result = PluginSpecHelper.run("cronvar", {
      "name"                => "MAILTO",
      "state"               => "bogus",
      "cron_file"           => tmp_path("cronvar-check-mode-bad-state.txt"),
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, got: bogus")
  end

  it "writes a timestamped backup before changing when backup=true" do
    path = tmp_path("cronvar-backup.txt")
    File.write(path, "MAILTO=root\n")

    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "ops@example.com",
      "cron_file" => path,
      "backup"    => "true",
    })

    result["changed"].as_bool.must_equal(true)
    backup_file = result["backup_file"].as_s
    File.exists?(backup_file).must_equal(true)
    File.read(backup_file).must_equal("MAILTO=root\n")
  end

  it "fails with the Ansible module's message when value is missing for state=present" do
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "cron_file" => tmp_path("cronvar-missing-value.txt"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("You must specify 'value' to insert a new cron variable")
  end

  it "fails when insertbefore and insertafter are both given" do
    result = PluginSpecHelper.run("cronvar", {
      "name"         => "MAILTO",
      "value"        => "root",
      "cron_file"    => tmp_path("cronvar-mutually-exclusive.txt"),
      "insertafter"  => "SHELL",
      "insertbefore" => "SHELL",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("mutually exclusive")
  end

  # kpg32 seed 32: ansible-core 2.19.11 emits the arg_spec.py
  # wording verbatim, without the parentheses this plugin wrapped the
  # pair in.
  it "words the insertbefore/insertafter clash exactly like real arg_spec.py" do
    result = PluginSpecHelper.run("cronvar", {
      "name"         => "MAILTO",
      "value"        => "root",
      "cron_file"    => tmp_path("cronvar-mutually-exclusive.txt"),
      "insertafter"  => "SHELL",
      "insertbefore" => "SHELL",
    })

    result["msg"].as_s.must_equal("parameters are mutually exclusive: insertbefore|insertafter")
  end

  it "rejects a state outside the argument spec's choices" do
    result = PluginSpecHelper.run("cronvar", {
      "name"  => "MAILTO",
      "value" => "root",
      "state" => "present_x",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, got: present_x")
  end

  # Live-verified against ansible-core 2.19.11: arg_spec's
  # mutually_exclusive check runs before the per-parameter choices
  # check, which in turn runs before the module body's own
  # "You must specify 'value'" check.
  it "checks mutual exclusion before the state choices, like Ansible" do
    result = PluginSpecHelper.run("cronvar", {
      "name"         => "MAILTO",
      "state"        => "bogus",
      "insertafter"  => "SHELL",
      "insertbefore" => "PATH",
    })

    result["msg"].as_s.must_equal("parameters are mutually exclusive: insertbefore|insertafter")
  end

  # A `crontab` shim that reads an empty crontab and records the staged
  # file the install half is handed, so the live-crontab path can be
  # pinned without touching the suite host's real crontab.
  describe "user crontab install" do
    private def staged_install(params : Hash(String, String), tag : String) : {String, String}
      shim_dir = tmp_path("cronvar-install-bin-#{tag}")
      Dir.mkdir_p(shim_dir)
      staged_content = tmp_path("cronvar-installed-content-#{tag}")
      staged_path = tmp_path("cronvar-installed-path-#{tag}")
      shim = File.join(shim_dir, "crontab")
      File.write(shim, <<-SH)
        #!/bin/sh
        if [ "$1" = "-l" ]; then
          echo "no crontab for root" >&2
          exit 1
        fi
        printf '%s' "$1" > #{staged_path}
        cp "$1" #{staged_content}
        exit 0
      SH
      File.chmod(shim, 0o755)

      result = PluginSpecHelper.run("cronvar", params, env: {"PATH" => "#{shim_dir}:/usr/bin:/bin"})
      result["changed"].as_bool.must_equal(true)
      {File.read(staged_content), File.read(staged_path)}
    end

    # kpg cronvar chaos #22 (issue #1854): insertbefore naming a variable
    # the crontab does not hold drops the new line but still reinstalls
    # the crontab - real cronvar's own quirk. Real CronVar.write()
    # renders "" for that and stages it through
    # tempfile.mkstemp(prefix="crontab"), and `crontab` stamps that path
    # AND the wall clock into the crontab file's own
    # "# (/tmp/crontabXXXXXXXX installed on ...)" header - so the empty
    # body and the name's 20-character shape both end up on the host.
    it "installs an emptied crontab as an empty file at Ansible's /tmp/crontabXXXXXXXX path" do
      content, path = staged_install({
        "name"         => "efimnk",
        "value"        => "xyzzly",
        "state"        => "present",
        "insertbefore" => "cctyml",
      }, "emptied")

      content.must_equal("")
      path.must_match(%r{\A/tmp/crontab[a-z0-9_]{8}\z})
    end

    it "stages exactly the rendered crontab, with no added blank line" do
      content, _ = staged_install({"name" => "MAILTO", "value" => "admin@example.com"}, "rendered")

      content.must_equal("MAILTO=admin@example.com\n")
    end
  end

  # Real community.general cronvar's result shape (live-verified against
  # ansible-core 2.19.11): changed + vars (the full current var-name
  # list), plus cron_file/backup_file only when they apply - a backup
  # key is present ONLY when a backup was actually retained.
  describe "result shape (Ansible's field set)" do
    it "carries vars as the full current var-name list after the change" do
      path = tmp_path("cronvar-shape.txt")
      File.delete(path) if File.exists?(path)

      PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})
      result = PluginSpecHelper.run("cronvar", {"name" => "SHELL", "value" => "/bin/sh", "cron_file" => path})

      result["vars"].as_a.map(&.as_s).must_equal(["SHELL", "MAILTO"])
      result["changed"].as_bool.must_equal(true)
    end

    it "omits backup_file when no backup was made" do
      path = tmp_path("cronvar-no-backup.txt")
      File.delete(path) if File.exists?(path)

      result = PluginSpecHelper.run("cronvar", {"name" => "MAILTO", "value" => "root", "cron_file" => path})

      result["backup_file"]?.must_be_nil
    end
  end
end

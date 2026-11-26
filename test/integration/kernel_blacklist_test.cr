require "../minitest_helper"

# All of these specs operate on a throwaway blacklist file under
# spec/tmp - never touching /etc/modprobe.d.

describe "kernel_blacklist plugin" do
  it "blacklists a module in a new file, creating it before the change" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-new.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["changed"].as_bool.must_equal(true)
    File.read(file).must_equal("blacklist krikri_mod\n")
  end

  it "is idempotent when the module is already blacklisted" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-idempotent.conf")
    File.write(file, "blacklist krikri_mod\n")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["changed"].as_bool.must_equal(false)
    File.read(file).must_equal("blacklist krikri_mod\n")
  end

  it "removes an entry with state absent" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-absent.conf")
    File.write(file, "# comment\nblacklist krikri_mod\nother line\n")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "state" => "absent", "blacklist_file" => file})

    result["changed"].as_bool.must_equal(true)
    File.read(file).must_equal("# comment\nother line\n")
  end

  it "does not write in check mode, but still creates a missing file" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-check-mode.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(file).must_equal(true)
    File.read(file).must_equal("")
  end

  # kpg issue #1860: the check-mode oracle fingerprints the empty file
  # kernel_blacklist leaves behind. kernel_blacklist.py creates it with a
  # bare `open(path, "a")` - 0666 masked by the process umask - so under a
  # group-write umask (002) it is 0664, not the 0644 Crystal's File.touch
  # used to pin.
  it "creates the missing blacklist file with Ansible's 0666 creation mode under --check" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-check-mode-create-mode.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist",
      {"name" => "krikri_mod", "blacklist_file" => file, "_ansible_check_mode" => "true"},
      umask: 0o002)

    result["changed"].as_bool.must_equal(true)
    File.read(file).must_equal("")
    File.info(file).permissions.value.must_equal(0o664)
  end

  it "rejects a user-supplied check_mode module param like Ansible's unsupported-params validator" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-check-mode-param.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file, "check_mode" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unsupported parameters for (community.general.kernel_blacklist) module: check_mode. Supported parameters include: blacklist_file, name, state.")
    File.exists?(file).must_equal(false)
  end

  it "strips trailing whitespace when rewriting (Ansible's rstrip line read)" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-rstrip.conf")
    File.write(file, "blacklist other   \n")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["changed"].as_bool.must_equal(true)
    File.read(file).must_equal("blacklist other\nblacklist krikri_mod\n")
  end

  it "reports Ansible's missing-required-arguments wording" do
    result = PluginSpecHelper.run("kernel_blacklist", {} of String => String)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "reports Ansible's choices wording in the spec's declaration order (absent, present)" do
    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "k", "state" => "bogus"})
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, got: bogus")
  end

  it "reports Ansible's unsupported-parameters wording" do
    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "k", "krikri_param" => "yes"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unsupported parameters for (community.general.kernel_blacklist) module: krikri_param. " \
                                  "Supported parameters include: blacklist_file, name, state.")
  end

  it "emits no msg key on success (Ansible's StateModuleHelper output has no msg)" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-no-msg.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})
    result["changed"].as_bool.must_equal(true)
    result.as_h.has_key?("msg").must_equal(false)
  end

  it "fails with Ansible's wrapped Errno-2 open failure when the parent dir is missing (no mkdir_p)" do
    parent = PluginSpecHelper.tmp_path("kernel-blacklist-missing-parent")
    Dir.delete(parent) if Dir.exists?(parent)
    file = File.join(parent, "blacklist.conf")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Module failed with exception: [Errno 2] No such file or directory: '#{file}'")
    File.exists?(file).must_equal(false)
  end

  # kpg issue #1654: the module's only diff-flagged variable is `lines`,
  # so --diff pins the file content before/after. Verified against real
  # ansible-core 2.21.6 + community.general 13.2.0:
  #   changed:   {"before": {"lines": []}, "after": {"lines": ["blacklist stxgie"]}}
  #   unchanged: {}
  #   no --diff: no diff key at all.
  it "reports the lines VarDict diff under --diff" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-diff-new.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist",
      {"name" => "stxgie", "blacklist_file" => file, "_ansible_diff" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["diff"]["before"]["lines"].as_a.must_be_empty
    result["diff"]["after"]["lines"].as_a.map(&.as_s).must_equal(["blacklist stxgie"])
  end

  it "reports an empty diff dict on an unchanged --diff rerun" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-diff-unchanged.conf")
    File.write(file, "blacklist stxgie\n")

    result = PluginSpecHelper.run("kernel_blacklist",
      {"name" => "stxgie", "blacklist_file" => file, "_ansible_diff" => "true"})

    result["changed"].as_bool.must_equal(false)
    result["diff"].as_h.must_be_empty
  end

  it "emits no diff key at all without --diff" do
    file = PluginSpecHelper.tmp_path("kernel-blacklist-no-diff.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "stxgie", "blacklist_file" => file})

    result.as_h.has_key?("diff").must_equal(false)
  end

  it "carries the empty diff dict in output but not vars on an --diff failure" do
    parent = PluginSpecHelper.tmp_path("kernel-blacklist-diff-missing-parent")
    Dir.delete(parent) if Dir.exists?(parent)
    file = File.join(parent, "blacklist.conf")

    result = PluginSpecHelper.run("kernel_blacklist",
      {"name" => "stxgie", "blacklist_file" => file, "_ansible_diff" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["diff"].as_h.must_be_empty
    result["output"].as_h.has_key?("diff").must_equal(true)
    result["output"]["diff"].as_h.must_be_empty
    result["vars"].as_h.has_key?("diff").must_equal(false)
  end
end

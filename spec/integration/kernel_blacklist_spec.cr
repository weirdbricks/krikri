require "../spec_helper"

# All of these specs operate on a throwaway blacklist file under
# spec/tmp - never touching /etc/modprobe.d.

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "kernel_blacklist plugin" do
  it "blacklists a module in a new file, creating it before the change" do
    file = tmp_path("kernel-blacklist-new.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["changed"].as_bool.should be_true
    File.read(file).should eq("blacklist krikri_mod\n")
  end

  it "is idempotent when the module is already blacklisted" do
    file = tmp_path("kernel-blacklist-idempotent.conf")
    File.write(file, "blacklist krikri_mod\n")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["changed"].as_bool.should be_false
    File.read(file).should eq("blacklist krikri_mod\n")
  end

  it "removes an entry with state absent" do
    file = tmp_path("kernel-blacklist-absent.conf")
    File.write(file, "# comment\nblacklist krikri_mod\nother line\n")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "state" => "absent", "blacklist_file" => file})

    result["changed"].as_bool.should be_true
    File.read(file).should eq("# comment\nother line\n")
  end

  it "does not write in check mode, but still creates a missing file" do
    file = tmp_path("kernel-blacklist-check-mode.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(file).should be_true
    File.read(file).should eq("")
  end

  it "rejects a user-supplied check_mode module param like real's unsupported-params validator" do
    file = tmp_path("kernel-blacklist-check-mode-param.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file, "check_mode" => "true"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.kernel_blacklist) module: check_mode. Supported parameters include: blacklist_file, name, state.")
    File.exists?(file).should be_false
  end

  it "strips trailing whitespace when rewriting (real's rstrip line read)" do
    file = tmp_path("kernel-blacklist-rstrip.conf")
    File.write(file, "blacklist other   \n")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["changed"].as_bool.should be_true
    File.read(file).should eq("blacklist other\nblacklist krikri_mod\n")
  end

  it "reports real's missing-required-arguments wording" do
    result = PluginSpecHelper.run("kernel_blacklist", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "reports real's choices wording in the spec's declaration order (absent, present)" do
    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "k", "state" => "bogus"})
    result["msg"].as_s.should eq("value of state must be one of: absent, present, got: bogus")
  end

  it "reports real's unsupported-parameters wording" do
    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "k", "krikri_param" => "yes"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.kernel_blacklist) module: krikri_param. " \
                                 "Supported parameters include: blacklist_file, name, state.")
  end

  it "emits no msg key on success (real's StateModuleHelper output has no msg)" do
    file = tmp_path("kernel-blacklist-no-msg.conf")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})
    result["changed"].as_bool.should be_true
    result.as_h.has_key?("msg").should be_false
  end

  it "fails with real's wrapped Errno-2 open failure when the parent dir is missing (no mkdir_p)" do
    parent = tmp_path("kernel-blacklist-missing-parent")
    Dir.delete(parent) if Dir.exists?(parent)
    file = File.join(parent, "blacklist.conf")

    result = PluginSpecHelper.run("kernel_blacklist", {"name" => "krikri_mod", "blacklist_file" => file})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Module failed with exception: [Errno 2] No such file or directory: '#{file}'")
    File.exists?(file).should be_false
  end
end

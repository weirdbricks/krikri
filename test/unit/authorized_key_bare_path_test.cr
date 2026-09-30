require "../minitest_helper"
require "file_utils"
require "../../src/krikri/param_sentinels"

# Regression spec (sweep29 000020-authorized_key-chaos): an explicit
# `path: 9` (a non-string YAML int literal, whose type: path spec
# coerces it to the string "9") has Python os.path.dirname("9") == "" -
# NOT Crystal's "." - so real 2.19.11 fails the task:
# - manage_dir false: the keysfile branch's uncaught os.makedirs("")
#   crash, "Task failed: Module failed: [Errno 2] No such file or
#   directory: ''";
# - manage_dir true: the fail_json'd mkdir("") failure, "Failed to
#   create directory  : [Errno 2] No such file or directory: ''"
#   (double space - the empty dirname is interpolated).
# krikri previously used Crystal's dirname(".") semantics, silently
# created/wrote a bare relative file and reported changed.
#
# All cases run against a scratch cwd (PluginSpecHelper.run's chdir:)
# so neither engine-visible state nor the suite's own directory is
# touched, and nothing here depends on running as root: both mkdir("")
# and makedirs("") fail for any user.
describe "authorized_key: bare relative path has Python's empty dirname" do
  it "fails with the makedirs('') crash shape when manage_dir is false" do
    cwd = PluginSpecHelper.tmp_path("ak-bare-path")
    FileUtils.mkdir_p(cwd)

    result = PluginSpecHelper.run("authorized_key", {
      "user"       => "root",
      "key"        => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg",
      "path"       => Krikri::NON_STRING_PARAM_PREFIX + "9",
      "manage_dir" => "false",
    }, chdir: cwd)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: [Errno 2] No such file or directory: ''")
    # ... and nothing was written: no file named "9" in the cwd.
    File.exists?(File.join(cwd, "9")).must_equal(false)
  end

  it "fails with the fail_json'd mkdir('') shape when manage_dir is true" do
    cwd = PluginSpecHelper.tmp_path("ak-bare-path-managed")
    FileUtils.mkdir_p(cwd)

    result = PluginSpecHelper.run("authorized_key", {
      "user"       => "root",
      "key"        => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg",
      "path"       => Krikri::NON_STRING_PARAM_PREFIX + "9",
      "manage_dir" => "true",
    }, chdir: cwd)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to create directory  : [Errno 2] No such file or directory: ''")
    File.exists?(File.join(cwd, "9")).must_equal(false)
  end

  it "still creates a missing relative subdirectory and reports changed" do
    cwd = PluginSpecHelper.tmp_path("ak-relative-path")
    FileUtils.mkdir_p(cwd)

    result = PluginSpecHelper.run("authorized_key", {
      "user"       => "root",
      "key"        => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg",
      "path"       => "no/such/dir/ak.txt",
      "manage_dir" => "false",
    }, chdir: cwd)

    # a success result carries no "failed" key at all
    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(cwd, "no/such/dir/ak.txt")).must_equal(true)
  end
end

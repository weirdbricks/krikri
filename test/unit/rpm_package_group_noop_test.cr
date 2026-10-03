require "../minitest_helper"
require "file_utils"

# Round 900999 tcosta84.yum: a package-group (`@Group Name`) install was
# never idempotent on a warm rerun - this engine always reported
# changed: true because it trusted exit_code plus the plain-package
# "Nothing to do" text, which a no-op GROUP install never prints. Real
# yum/dnf CLI's own no-op shape for an already-installed group
# (live-captured from a rockylinux:9 container: `yum -y install
# @"Development tools"` run twice) is a full successful run whose
# Transaction Summary section lists NO `Install N Packages` /
# `Upgrade N Packages` count line at all, just the `====` rule and then
# `Complete!` - while an actual install always carries at least one such
# count line. These specs drive the real yum plugin binary against a
# fake `yum` on PATH replaying both captured output shapes verbatim.
NOOP_GROUP_OUTPUT = <<-YUM
  Last metadata expiration check: 0:01:10 ago on Sat Sep 19 13:26:53 2026.
  Dependencies resolved.
  ================================================================================
   Package           Architecture     Version             Repository         Size
  ================================================================================
  Installing Groups:
   Development Tools

  Transaction Summary
  ================================================================================

  Complete!
  YUM

ACTUAL_GROUP_OUTPUT = <<-YUM
  Last metadata expiration check: 0:01:12 ago on Sat Sep 19 13:26:53 2026.
  Dependencies resolved.
  ================================================================================
   Package           Architecture     Version             Repository         Size
  ================================================================================
  Installing Groups:
   Development Tools

  Transaction Summary
  ================================================================================
  Install  418 Packages
  Upgrade    3 Packages

  Complete!
  YUM

private def with_fake_yum(output : String, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-yum")
  Dir.mkdir_p(shim_dir)
  File.write("#{shim_dir}/yum", "#!/bin/sh\ncat <<'KRIKRI_FAKE_YUM_EOF'\n#{output}\nKRIKRI_FAKE_YUM_EOF\n")
  File.chmod("#{shim_dir}/yum", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "yum: package-group install idempotency" do
  it "reports changed: false for an already-installed group (empty Transaction Summary)" do
    with_fake_yum(NOOP_GROUP_OUTPUT) do
      result = PluginSpecHelper.run("yum", {"name" => "@Development tools", "state" => "present"})
      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      # real's no-op shape (dnf/yum exit_json(**response) with nothing
      # resolved): msg "Nothing to do", empty results - NOT a prose
      # summary naming the already-satisfied group.
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end

  it "still reports changed: true for a group with real Install/Upgrade counts" do
    with_fake_yum(ACTUAL_GROUP_OUTPUT) do
      result = PluginSpecHelper.run("yum", {"name" => "@Development tools", "state" => "present"})
      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      # A group has no NEVRA of its own, so real-shaped `results` names
      # the requested spec.
      result["msg"].as_s.must_equal("")
      result["results"].as_a.first.as_s.must_equal("Installed: @Development tools")
    end
  end
end

require "../spec_helper"
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
  shim_dir = "#{File.expand_path("..", __DIR__)}/tmp-fake-yum-#{Process.pid}"
  Dir.mkdir_p(shim_dir)
  File.write("#{shim_dir}/yum", "#!/bin/sh\ncat <<'KRIKRI_FAKE_YUM_EOF'\n#{output}\nKRIKRI_FAKE_YUM_EOF\n")
  File.chmod("#{shim_dir}/yum", 0o755)
  old_path = ENV["PATH"]?
  ENV["PATH"] = "#{shim_dir}:#{old_path}"
  yield
ensure
  ENV["PATH"] = old_path if old_path
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "yum: package-group install idempotency" do
  it "reports changed: false for an already-installed group (empty Transaction Summary)" do
    with_fake_yum(NOOP_GROUP_OUTPUT) do
      result = PluginSpecHelper.run("yum", {"name" => "@Development tools", "state" => "present"})
      result["failed"]?.should be_nil
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should contain("already satisfied")
    end
  end

  it "still reports changed: true for a group with real Install/Upgrade counts" do
    with_fake_yum(ACTUAL_GROUP_OUTPUT) do
      result = PluginSpecHelper.run("yum", {"name" => "@Development tools", "state" => "present"})
      result["failed"]?.should be_nil
      result["changed"].as_bool.should be_true
      result["msg"].as_s.should contain("Installed: @Development tools")
    end
  end
end

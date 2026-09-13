require "../spec_helper"
require "file_utils"

# Real ansible.builtin.dnf/yum treat a scalar `list:` value as a QUERY,
# never as packages to act on - `dnf: {list: updates}` lists available
# updates and returns {"changed": false, "results": [...]}. The dnf/yum
# plugins' parse_package_names used to concatenate a scalar `list:` into
# the package names instead, so `dnf: {list: updates}` ran
# `dnf install updates` and failed with "Error: Unable to find a match:
# updates" where real ansible-playbook succeeded (rc=0). Found via
# oatakan.rhel_upgrade's own "check for missing updates (dnf)" task
# (round 310183).
#
# There is no real dnf on the spec host, so a fake `dnf`/`yum`
# executable is put on PATH printing realistic `dnf list <spec>` output -
# the plugin shells out through remote_exec -> LocalExecutor, which
# inherits the process environment, exactly like the real thing does on
# a target host.
FAKE_LIST_OUTPUT = [
  "Last metadata expiration check: 0:00:32 ago on Fri 11 Sep 2026 02:13:26 AM EDT.",
  "",
  "Available Upgrades",
  "kernel.x86_64                        5.14.0-427.13.1.el9_4     baseos",
  "kernel-tools.x86_64                  5.14.0-427.13.1.el9_4     baseos",
  "openssl-libs.x86_64                  1:1.1.1k-9.el8_7          security",
].join("\n") + "\n"

def with_fake_pkg_manager(name : String, output : String, &block)
  bin_dir = File.tempname("krikri-fake-pkgmgr")
  Dir.mkdir_p(bin_dir)
  script = File.join(bin_dir, name)
  File.write(script, "#!/bin/sh\nprintf '%s' \"#{output}\"")
  File.chmod(script, 0o755)
  previous = ENV["PATH"]?
  ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
  begin
    block.call
  ensure
    previous ? (ENV["PATH"] = previous) : ENV.delete("PATH")
    FileUtils.rm_r(bin_dir)
  end
end

describe "dnf/yum list: query mode" do
  it "returns a results array for the magic `updates` spec instead of installing it" do
    with_fake_pkg_manager("dnf", FAKE_LIST_OUTPUT) do
      result = PluginSpecHelper.run("dnf", {
        "list"  => "updates",
        "state" => "present",
      })

      result["changed"].as_bool.should be_false
      result["failed"]?.try(&.as_bool).should be_falsey
      results = result["results"].as_a
      results.size.should eq(3)

      first = results[0].as_h
      first["name"].as_s.should eq("kernel")
      first["arch"].as_s.should eq("x86_64")
      first["version"].as_s.should eq("5.14.0")
      first["release"].as_s.should eq("427.13.1.el9_4")
      first["repo"].as_s.should eq("baseos")
      first["epoch"].as_s?.should be_nil
      first["nevra"].as_s.should eq("kernel-5.14.0-427.13.1.el9_4.x86_64")

      with_epoch = results[2].as_h
      with_epoch["name"].as_s.should eq("openssl-libs")
      with_epoch["epoch"].as_s.should eq("1")
      with_epoch["version"].as_s.should eq("1.1.1k")
      with_epoch["release"].as_s.should eq("9.el8_7")
      with_epoch["nevra"].as_s.should eq("openssl-libs-1:1.1.1k-9.el8_7.x86_64")
    end
  end

  it "does the same through the yum plugin" do
    with_fake_pkg_manager("yum", FAKE_LIST_OUTPUT) do
      result = PluginSpecHelper.run("yum", {
        "list"  => "updates",
        "state" => "present",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["results"].as_a.size.should eq(3)
      result["results"].as_a[0].as_h["name"].as_s.should eq("kernel")
    end
  end

  it "returns an empty results array when nothing matches" do
    with_fake_pkg_manager("dnf", "Last metadata expiration check: 0:00:32 ago\n") do
      result = PluginSpecHelper.run("dnf", {
        "list"  => "updates",
        "state" => "present",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["results"].as_a.size.should eq(0)
    end
  end
end

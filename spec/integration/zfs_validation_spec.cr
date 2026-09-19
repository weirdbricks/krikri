require "../spec_helper"
require "file_utils"

# Parameter-coverage pass for `community.general.zfs:`'s argument
# validation, matching real AnsibleModule's construction-time behavior:
# required args (name AND state, sorted into one plural message), the
# state choices (in the spec's own "absent, present" order, with the
# "got:" colon), and the origin-on-snapshot check that real zfs.py runs
# BEFORE Zfs.__init__ resolves the zfs/zpool binaries - so a host
# without ZFS still fails origin-on-snapshot with the module's message,
# not the get_bin_path one. Found via the zfs_edge_cases podman-diff
# case (no container has /dev/zfs, so nothing here mutates real ZFS
# state); the W6/W7-style binary-lookup failure is asserted under a
# restricted PATH so it's deterministic whether or not this spec
# machine has zfsutils installed.
private def run_zfs(params : Hash(String, String), path : String? = nil) : JSON::Any
  binary = File.join(PluginSpecHelper::PLUGINS_DIR, "zfs")
  raise "Plugin binary not found: #{binary} (run ./build.sh first)" unless File.exists?(binary)

  config = {
    "host" => {
      "name" => "localhost",
      "user" => ENV["USER"]? || "root",
      "port" => 22,
    },
    "params" => params,
    "vars"   => {} of String => String,
  }

  output = IO::Memory.new
  Process.run(binary, input: Process::Redirect::Pipe, output: output, error: Process::Redirect::Inherit,
    env: path ? {"PATH" => path} : nil) do |process|
    process.input.print(config.to_json)
    process.input.close
  end

  JSON.parse(output.to_s)
end

describe "zfs plugin - argument validation" do
  it "reports both missing required args, sorted, in the plural wording" do
    result = run_zfs({} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name, state")
  end

  it "reports a missing state alone" do
    result = run_zfs({"name" => "rpool/krikri"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: state")
  end

  it "reports a missing name alone" do
    result = run_zfs({"state" => "present"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "rejects an invalid state choice in the spec's own order with the got: colon" do
    result = run_zfs({"name" => "rpool/krikri", "state" => "krikri_bogus"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, present, got: krikri_bogus")
  end

  it "fails origin-on-snapshot before the zfs/zpool binary lookup" do
    result = run_zfs({
      "name"   => "rpool/krikri@snap",
      "state"  => "present",
      "origin" => "rpool/other@snap",
    }, path: "/nonexistent-krikri-spec-path")
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("cannot specify origin when operating on a snapshot")
  end

  it "fails the binary lookup with real's quoted-executable wording" do
    result = run_zfs({"name" => "rpool/krikri", "state" => "present"}, path: "/nonexistent-krikri-spec-path")
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Failed to find required executable \"zfs\" in paths: /nonexistent-krikri-spec-path")
  end
end

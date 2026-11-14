require "../minitest_helper"
require "json"

# ansible.builtin.mount_facts is read-only, so these specs run the real
# plugin binary directly against the host they run on (/proc/mounts and
# /etc/fstab exist on every Linux benchmark/dev box), pinning the documented
# output shape rather than mocking the filesystem.
private def run_mount_facts(params_json : String = "{}") : JSON::Any
  config = {
    "params" => JSON.parse(params_json),
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/mount_facts", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

describe "mount_facts: ansible_facts shape" do
  it "returns mount_points and aggregate_mounts, unfiltered, on a real host" do
    result = run_mount_facts
    result["failed"]?.try(&.as_bool).must_equal(false) if result["failed"]?
    facts = result["ansible_facts"]?
    facts.wont_be_nil("no ansible_facts returned: #{result}")

    mount_points = facts.not_nil!["mount_points"]?
    mount_points.wont_be_nil
    mount_points.not_nil!.as_h?.wont_be_nil
    # Every Linux host reading /proc/mounts yields at least one entry.
    expect((mount_points.not_nil!.as_h.size) > (0)).must_equal(true)

    # aggregate_mounts is always present (empty unless requested).
    facts.not_nil!["aggregate_mounts"]?.not_nil!.as_a?.wont_be_nil
  end

  it "tags each entry with its mount/device/fstype and source ansible_context" do
    mount_points = run_mount_facts["ansible_facts"]["mount_points"].as_h
    mount_points.each do |point, entry|
      h = entry.as_h
      h["mount"].as_s.must_equal(point)
      h.has_key?("device").must_equal(true)
      h.has_key?("fstype").must_equal(true)
      ctx = h["ansible_context"].as_h
      ctx["source"].as_s.wont_be_empty
      ctx.has_key?("source_data").must_equal(true)
      # The dynamic /proc/mounts source carries statvfs-derived size fields.
      if ctx["source"].as_s == "/proc/mounts"
        h.has_key?("block_total").must_equal(true)
        expect((h["inode_total"].as_i64) >= (0i64)).must_equal(true)
      end
    end
  end

  it "filters by fstypes, dropping every non-matching mount" do
    mount_points = run_mount_facts(%q({"fstypes": "[\"zzz-no-such-fs\"]"}))["ansible_facts"]["mount_points"].as_h
    mount_points.size.must_equal(0)
  end

  it "filters by devices, dropping every non-matching mount" do
    mount_points = run_mount_facts(%q({"devices": "[\"zzz-no-such-device-*\"]"}))["ansible_facts"]["mount_points"].as_h
    mount_points.size.must_equal(0)
  end

  it "honours an fnmatch fstype glob" do
    # "pro*" must match proc; the result must be a subset of the unfiltered
    # set and every entry must be of a matching fstype. List params reach
    # the plugin as a JSON-encoded string (the executor's wire format),
    # not a nested JSON array.
    filtered = run_mount_facts(%q({"fstypes": "[\"pro*\"]"}))["ansible_facts"]["mount_points"].as_h
    unfiltered = run_mount_facts["ansible_facts"]["mount_points"].as_h
    expect((filtered.size) > (0)).must_equal(true)
    expect((filtered.size) <= (unfiltered.size)).must_equal(true)
    filtered.each do |_point, entry|
      entry.as_h["fstype"].as_s.starts_with?("pro").must_equal(true)
    end
  end
end

describe "mount_facts: mount_facts.py main() argument guards" do
  # mount_facts.py declares mount_binary `type: raw` and timeout `type:
  # float`, so AnsibleModule's generic argspec checks let a wrong-typed
  # value through and main() rejects it itself. An unquoted YAML scalar
  # crosses the strings-only plugin wire under NON_STRING_PARAM_PREFIX,
  # which is the only place the native type survives.
  it "fails an unquoted non-string mount_binary like Ansible's own main() check" do
    result = run_mount_facts({"mount_binary" => Krikri::NON_STRING_PARAM_PREFIX + "81"}.to_json)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'mount_binary' must be a string or null, not 81")
  end

  it "fails a non-positive timeout like Ansible's own main() check" do
    result = run_mount_facts({"timeout" => "0"}.to_json)
    result["failed"].as_bool.must_equal(true)
    # Ansible reports the argspec-converted float, so an int 0 prints 0.0.
    result["msg"].as_s.must_equal("argument 'timeout' must be a positive number or null, not 0.0")
  end

  it "converts a native bool timeout the way Ansible's float checker does" do
    result = run_mount_facts({"timeout" => Krikri::NON_STRING_PARAM_PREFIX + "false"}.to_json)
    result["msg"].as_s.must_equal("argument 'timeout' must be a positive number or null, not 0.0")
  end

  it "keeps accepting a string mount_binary and an explicit null" do
    ["mount", Krikri::NONE_SENTINEL].each do |binary|
      result = run_mount_facts({"mount_binary" => binary}.to_json)
      result["failed"]?.try(&.as_bool).must_equal(false) if result["failed"]?
      result["ansible_facts"]?.wont_be_nil
    end
  end
end

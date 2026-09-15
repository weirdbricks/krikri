require "../spec_helper"
require "json"

# Regression for the podman-diff find_edge_cases O5c/O5e finding: real
# ansible-core's find module fails the whole task when `age:` or `size:`
# doesn't parse ("banana" etc. - message live-verified against bookworm's
# ansible-core 2.14) instead of silently dropping the filter and
# returning unfiltered matches.
private def run_find(params : Hash(String, String)) : JSON::Any
  config = {
    "params" => params,
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/find", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

describe "find: age/size parse validation" do
  it "fails on an unparseable age value" do
    result = run_find({"paths" => "/tmp", "age" => "banana"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("failed to process age")
  end

  it "fails on an unparseable size value" do
    result = run_find({"paths" => "/tmp", "size" => "banana"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("failed to process size")
  end

  it "still accepts valid age/size spellings" do
    dir = File.join(Dir.tempdir, "krikri-find-age-size-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir(dir)
    path = "#{dir}/a.txt"
    File.write(path, "x")
    # Backdate well clear of the age threshold: a just-written file's
    # float mtime can sit a fraction of a second ahead of the plugin's
    # integer `now` (negative elapsed), and an exactly-1h-old file sits
    # on the >= 3600 boundary - both fail `age: 1h` marginally, the
    # same race real Ansible's own float time math has.
    File.utime(Time.utc - 2.hours, Time.utc - 2.hours, path)
    result = run_find({"paths" => dir, "recurse" => "true", "age" => "1h", "size" => "-1m"})
    (result["failed"]?.nil? || result["failed"].as_bool == false).should be_true
    result["matched"].as_i.should eq(1)
    `rm -rf #{dir}`
  end
end

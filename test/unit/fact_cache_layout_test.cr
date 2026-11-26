require "../minitest_helper"
require "../../src/krikri/fact_cache"

# ansible-core 2.21's cache-persistence interposer
# (ansible/_internal/_plugins/_cache.py) stores every cache entry under a
# `s<schema_id>_`-prefixed key (schema_id is 1 in 2.21.6) and wraps the
# value as `{"__payload__": "<compact JSON of the facts>"}`. One cache
# directory has to serve both engines, so these pin the on-disk shape -
# filename and envelope - rather than only a krikri round trip.
describe "Krikri::FactCache jsonfile layout" do
  serial! # mutates process-global state (ENV)

  after_each do
    ENV.delete("ANSIBLE_CACHE_PLUGIN")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_PREFIX")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_TIMEOUT")
  end

  it "writes the s1_ prefixed file ansible reads, inside a __payload__ envelope" do
    dir = PluginSpecHelper.tmp_path("fact-cache-layout-write")
    Dir.mkdir_p(dir)
    enable_jsonfile_cache(dir)

    Krikri::FactCache.write("h", {"ansible_system" => JSON::Any.new("Linux")})

    # The pre-2.21 name must not be written too: one entry, one file.
    File.exists?(File.join(dir, "h")).must_equal(false)
    envelope = JSON.parse(File.read(File.join(dir, "s1_h"))).as_h
    # ansible stores the facts as a JSON STRING under __payload__, not as
    # a nested object.
    payload = envelope["__payload__"].as_s
    JSON.parse(payload).as_h["ansible_system"].as_s.must_equal("Linux")
  end

  it "reads an entry ansible itself wrote" do
    dir = PluginSpecHelper.tmp_path("fact-cache-layout-read")
    Dir.mkdir_p(dir)
    enable_jsonfile_cache(dir)

    payload = {"_ansible_facts_gathered" => true, "ansible_system" => "Linux"}.to_json
    File.write(File.join(dir, "s1_h"), {"__payload__" => payload}.to_json)

    # An empty fallback would fail the assertions below with the missing
    # key named, so the miss case still reports which fact went wrong.
    facts = Krikri::FactCache.read("h") || {} of String => JSON::Any
    facts["ansible_system"].as_s.must_equal("Linux")
    facts["_ansible_facts_gathered"].as_bool.must_equal(true)
  end

  it "ignores a bare <host> file from before the schema envelope" do
    dir = PluginSpecHelper.tmp_path("fact-cache-layout-legacy")
    Dir.mkdir_p(dir)
    enable_jsonfile_cache(dir)

    File.write(File.join(dir, "h"), {"ansible_system" => "Linux"}.to_json)

    Krikri::FactCache.read("h").must_be_nil
  end

  it "puts ANSIBLE_CACHE_PLUGIN_PREFIX before the schema marker, like ansible" do
    dir = PluginSpecHelper.tmp_path("fact-cache-layout-prefix")
    Dir.mkdir_p(dir)
    enable_jsonfile_cache(dir)
    ENV["ANSIBLE_CACHE_PLUGIN_PREFIX"] = "prod_"

    Krikri::FactCache.write("h", {"ansible_system" => JSON::Any.new("Linux")})

    File.exists?(File.join(dir, "prod_s1_h")).must_equal(true)
  end

  it "round-trips a wide integer as bare digits in the payload, as ansible's jsonfile stores it" do
    dir = PluginSpecHelper.tmp_path("fact-cache-layout-bigint")
    Dir.mkdir_p(dir)
    enable_jsonfile_cache(dir)
    digits = "123456789012345678901234567890"

    Krikri::FactCache.write("h", {"serial" => JSON::Any.new(Krikri.bigint_sentinel(digits))})

    payload = JSON.parse(File.read(File.join(dir, "s1_h"))).as_h["__payload__"].as_s
    # Bare digits inside the payload JSON: a Python int, not a quoted
    # sentinel string ansible would hand a play as text.
    payload.must_include(%("serial":#{digits}))
    # The read side restores the marker for the engine's own renderers.
    Krikri::FactCache.read("h").try(&.["serial"]?.try(&.as_s)).must_equal(Krikri.bigint_sentinel(digits))
  end
end

private def enable_jsonfile_cache(dir : String) : Nil
  ENV["ANSIBLE_CACHE_PLUGIN"] = "jsonfile"
  ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = dir
  # 0 = never expire, so a fixture's mtime can never turn this into a miss.
  ENV["ANSIBLE_CACHE_PLUGIN_TIMEOUT"] = "0"
end

require "file_utils"
require "../minitest_helper"
require "../../src/krikri/bigint_json"
require "../../src/krikri/fact_cache"

# The `community.general.pickle` fact-cache codec (issue #1838):
# `pickle.dump(value, protocol=2)` of the plain per-host fact mapping,
# with no `s1_` prefix and no `__payload__` envelope because the plugin
# declares `_persistent = False`. See fact_cache_pickle.cr for why the
# opcode allowlist is both sufficient and safe.
private FIXTURE        = File.join(__DIR__, "..", "fixtures", "fact_cache", "ansible-2.21.6-local-gather.pickle")
private TAGGED_FIXTURE = File.join(__DIR__, "..", "fixtures", "fact_cache", "ansible-2.21.6-tagged-set-fact.pickle")

private def pickle_global(io : IO, module_name : String, class_name : String)
  io.write_byte(0x63_u8) # GLOBAL
  io << module_name << '\n' << class_name << '\n'
end

private def pickle_key(io : IO, text : String)
  bytes = text.to_slice
  io.write_byte(0x58_u8)
  io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
  io.write(bytes)
end

describe "Krikri::FactCache::Pickle" do
  it "decodes a pickle written by ansible-core 2.21.6 (sanitized local gather)" do
    facts = Krikri::FactCache::Pickle.decode(File.read(FIXTURE).to_slice)

    facts["ansible_system"].as_s.must_equal("Linux")
    facts["ansible_pkg_mgr"].as_s.must_equal("apt")
    facts["_ansible_facts_gathered"].as_bool.must_equal(true)
    facts["ansible_processor"].as_a.map(&.as_s).must_equal(["0", "GenuineIntel", "Intel(R) Xeon(R) CPU", "Unit test fixture"])
    mount = facts["ansible_mounts"].as_a.first.as_h
    mount["mount"].as_s.must_equal("/")
    mount["size_total"].as_i64.must_equal(107374182400_i64)
    facts["ansible_env"].as_h["PATH"].as_s.must_equal("/usr/bin:/bin")
    facts["ansible_selinux"].as_h["status"].as_s.must_equal("disabled")
  end

  it "decodes every integer width, floats, booleans and None" do
    facts = Krikri::FactCache::Pickle.decode(File.read(FIXTURE).to_slice)

    facts["fixture_int_zero"].as_i64.must_equal(0_i64)
    facts["fixture_int_255"].as_i64.must_equal(255_i64)
    facts["fixture_int_65535"].as_i64.must_equal(65535_i64)
    facts["fixture_int_binint"].as_i64.must_equal(70000_i64)
    facts["fixture_int_negative"].as_i64.must_equal(-129_i64)
    facts["fixture_int_i64max"].as_i64.must_equal(Int64::MAX)
    facts["fixture_float"].as_f.must_be_close_to(0.30000000000000004, 1e-15)
    facts["fixture_true"].as_bool.must_equal(true)
    facts["fixture_false"].as_bool.must_equal(false)
    facts["fixture_none"].raw.must_be_nil
  end

  it "restores an integer beyond Int64 as the bigint sentinel string" do
    facts = Krikri::FactCache::Pickle.decode(File.read(FIXTURE).to_slice)

    Krikri.bigint_digits(facts["fixture_int_wide"]).must_equal("123456789012345678901234567890")
  end

  it "decodes non-ASCII BINUNICODE values unchanged" do
    facts = Krikri::FactCache::Pickle.decode(File.read(FIXTURE).to_slice)

    facts["fixture_unicode"].as_s.must_equal("krikri \u2014 caf\u00e9 \u00fcn\u00efcode \u4f60\u597d")
  end

  it "resolves memo back-references to the same value (python's shared object)" do
    facts = Krikri::FactCache::Pickle.decode(File.read(FIXTURE).to_slice)

    facts["fixture_shared_a"].as_h.must_equal(facts["fixture_shared_b"].as_h)
    facts["fixture_shared_a"].as_h["nested"].as_a.map(&.as_i64).must_equal([1_i64, 2_i64, 3_i64])
  end

  it "round-trips the fixture through encode and decode" do
    original = Krikri::FactCache::Pickle.decode(File.read(FIXTURE).to_slice)
    encoded = Krikri::FactCache::Pickle.encode(original)

    encoded[0].must_equal(0x80_u8)
    encoded[1].must_equal(2_u8)
    encoded[-1].must_equal(0x2e_u8)

    Krikri::FactCache::Pickle.decode(encoded).must_equal(original)
  end

  it "round-trips a tree containing every value shape the writer emits" do
    facts = {
      "s"        => JSON::Any.new("text \u00e9"),
      "i"        => JSON::Any.new(70000_i64),
      "neg"      => JSON::Any.new(-70000_i64),
      "f"        => JSON::Any.new(1.5),
      "t"        => JSON::Any.new(true),
      "n"        => JSON::Any.new(nil),
      "empty_a"  => JSON::Any.new(Array(JSON::Any).new),
      "empty_h"  => JSON::Any.new(Hash(String, JSON::Any).new),
      "nest"     => JSON::Any.new([JSON::Any.new({"k" => JSON::Any.new(1_i64)})]),
      "wide"     => JSON::Any.new(Krikri.bigint_sentinel("123456789012345678901234567890")),
      "wide_neg" => JSON::Any.new(Krikri.bigint_sentinel("-123456789012345678901234567890")),
    }

    Krikri::FactCache::Pickle.decode(Krikri::FactCache::Pickle.encode(facts)).must_equal(facts)
  end

  it "encodes a pickle python3 loads into the same value" do
    python = Process.find_executable("python3")
    skip "python3 not available" unless python

    facts = {
      "text"  => JSON::Any.new("caf\u00e9"),
      "int"   => JSON::Any.new(70000_i64),
      "big"   => JSON::Any.new(Krikri.bigint_sentinel("123456789012345678901234567890")),
      "float" => JSON::Any.new(0.25),
      "list"  => JSON::Any.new([JSON::Any.new(1_i64), JSON::Any.new("two")]),
      "none"  => JSON::Any.new(nil),
      "wide"  => JSON::Any.new(Krikri.bigint_sentinel("-123456789012345678901234567890")),
      # Past LONG1's 255-byte limit, so this exercises LONG4 (2**3000).
      "huge" => JSON::Any.new(Krikri.bigint_sentinel((BigInt.new(1) << 3000).to_s)),
    }

    path = PluginSpecHelper.tmp_path("fact_cache_pickle_python_check.pickle")
    File.write(path, Krikri::FactCache::Pickle.encode(facts))
    script = "import json,pickle,sys;d=pickle.load(open(sys.argv[1],'rb'));print(json.dumps(d,sort_keys=True))"

    output = IO::Memory.new
    status = Process.run(python, ["-c", script, path], output: output, error: output)
    status.success?.must_equal(true)
    Krikri::BigJson.parse(output.to_s).must_equal(Krikri::BigJson.parse(facts.to_json))
  end

  it "decodes a cache entry holding ansible's data-tagged set_fact values" do
    # Captured from ansible-core 2.21.6's community.general.pickle plugin
    # after `set_fact: ... cacheable: true` of a templated string, i.e. a
    # value ansible stores as _AnsibleTaggedStr and pickles with
    # GLOBAL/NEWOBJ/BUILD plus class-keyed tag bookkeeping maps.
    facts = Krikri::FactCache::Pickle.decode(File.read(TAGGED_FIXTURE).to_slice)

    facts["fixture_tagged_value"].as_s.must_equal("from-template")
    facts["ansible_system"].as_s.must_equal("Linux")
    facts["ansible_pkg_mgr"].as_s.must_equal("apt")
    facts["_ansible_facts_gathered"].as_bool.must_equal(true)
  end

  it "refuses a GLOBAL outside the ansible datatag/unsafe modules" do
    # b"\x80\x02cos\nsystem\nq\x00X\x04\x00\x00\x00id\x85R." - the shape of
    # a code-execution pickle; it must be rejected, not partially read.
    payload = Bytes[0x80, 0x02, 0x63, 0x6f, 0x73, 0x0a, 0x73, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x0a]
    assert_raises_message(Krikri::FactCache::Pickle::Unsupported, "unsupported pickle GLOBAL os.system") do
      Krikri::FactCache::Pickle.decode(payload + Bytes[0x2e])
    end
  end

  it "refuses an opcode outside the supported subset" do
    assert_raises_message(Krikri::FactCache::Pickle::Unsupported, "unsupported pickle opcode") do
      Krikri::FactCache::Pickle.decode(Bytes[0x80, 0x02, 0x7d, 0x82, 0x2e])
    end
  end

  it "round-trips Int64 boundaries as integers, never sentinel strings" do
    values = [
      Int64::MIN, Int64::MIN + 1, -70000_i64, -129_i64, -128_i64, -1_i64,
      0_i64, 127_i64, 128_i64, 70000_i64, Int64::MAX - 1, Int64::MAX,
    ]
    facts = Hash(String, JSON::Any).new
    values.each_with_index { |value, index| facts["v#{index}"] = JSON::Any.new(value) }

    decoded = Krikri::FactCache::Pickle.decode(Krikri::FactCache::Pickle.encode(facts))
    values.each_with_index do |value, index|
      decoded["v#{index}"].as_i64.must_equal(value)
    end
  end

  it "encodes Int64::MIN in the minimal LONG1 width CPython uses" do
    # CPython's encode_long(-2**63) is 8 bytes (00..80), not 9. The bare
    # digits after the key are the LONG1 length byte, then the payload.
    encoded = Krikri::FactCache::Pickle.encode({"v" => JSON::Any.new(Int64::MIN)})
    encoded[10].must_equal(0x8a_u8)
    encoded[11].must_equal(8_u8)
  end

  it "round-trips integers too wide for LONG1 through LONG4" do
    digits = (BigInt.new(1) << 3000).to_s
    facts = {"wide" => JSON::Any.new(Krikri.bigint_sentinel(digits))}

    encoded = Krikri::FactCache::Pickle.encode(facts)
    encoded.to_slice.includes?(0x8b_u8).must_equal(true)
    Krikri.bigint_digits(Krikri::FactCache::Pickle.decode(encoded)["wide"]).must_equal(digits)
  end

  it "refuses a BINUNICODE length that overruns the stream instead of allocating it" do
    # A 7-byte file claiming a 2 GiB string.
    payload = Bytes[0x80, 0x02, 0x58, 0xff, 0xff, 0xff, 0x7f]
    assert_raises_message(Krikri::FactCache::Pickle::Error, "BINUNICODE length exceeds stream size") do
      Krikri::FactCache::Pickle.decode(payload)
    end
  end

  it "refuses a truncated stream instead of returning a partial mapping" do
    assert_raises(Krikri::FactCache::Pickle::Error) do
      Krikri::FactCache::Pickle.decode(Bytes[0x80, 0x02, 0x7d, 0x28])
    end
  end

  it "refuses a non-mapping root" do
    assert_raises(Krikri::FactCache::Pickle::Error) do
      Krikri::FactCache::Pickle.decode(Bytes[0x80, 0x02, 0x5d, 0x2e])
    end
  end
end

describe "Krikri::FactCache::Pickle safety gates" do
  it "refuses a memo back-reference that makes the mapping self-referential" do
    # EMPTY_DICT memo 0, key "self" memo 1, BINGET 0, SETITEM: {self: <same dict>}
    payload = Bytes[
      0x80, 0x02, 0x7d, 0x71, 0x00,
      0x58, 0x04, 0x00, 0x00, 0x00, 0x73, 0x65, 0x6c, 0x66, 0x71, 0x01,
      0x68, 0x00, 0x73, 0x2e,
    ]
    assert_raises_message(Krikri::FactCache::Pickle::Error, "recursive pickle structure") do
      Krikri::FactCache::Pickle.decode(payload)
    end
  end

  it "refuses a mapping with a non-string key" do
    # EMPTY_DICT, key 1 (BININT1), value 2 (BININT1), SETITEM
    payload = Bytes[0x80, 0x02, 0x7d, 0x4b, 0x01, 0x4b, 0x02, 0x73, 0x2e]
    assert_raises_message(Krikri::FactCache::Pickle::Error, "non-string key") do
      Krikri::FactCache::Pickle.decode(payload)
    end
  end

  it "refuses SETITEM against a non-mapping target" do
    # EMPTY_LIST, empty-string key, int value, SETITEM
    payload = Bytes[0x80, 0x02, 0x5d, 0x58, 0x00, 0x00, 0x00, 0x00, 0x4b, 0x02, 0x73, 0x2e]
    assert_raises_message(Krikri::FactCache::Pickle::Error, "not a mapping") do
      Krikri::FactCache::Pickle.decode(payload)
    end
  end

  it "charges copied tuple elements against the decode budget" do
    # A memoized 50k-element tuple re-BINGET as a SETITEM value, into a
    # dict the run throws away: copying is the amplification, so the
    # budget must cover it (not just the surviving tree).
    io = IO::Memory.new
    io.write_byte(0x80_u8)
    io.write_byte(0x02_u8)
    io.write_byte(0x28_u8) # MARK
    50_000.times { io.write_byte(0x4e_u8) }
    io.write_byte(0x74_u8) # TUPLE
    io.write_byte(0x71_u8) # BINPUT 0
    io.write_byte(0x00_u8)
    io.write_byte(0x7d_u8) # EMPTY_DICT (root)
    25.times do
      pickle_key(io, "k")
      io.write_byte(0x68_u8) # BINGET 0 (tuple -> fresh array)
      io.write_byte(0x00_u8)
      io.write_byte(0x73_u8) # SETITEM
    end
    io.write_byte(0x2e_u8) # STOP

    assert_raises_message(Krikri::FactCache::Pickle::Unsupported, "pickle graph too large") do
      Krikri::FactCache::Pickle.decode(io.to_slice)
    end
  end

  it "refuses a tag placeholder that survives into the facts" do
    io = IO::Memory.new
    io.write_byte(0x80_u8)
    io.write_byte(0x02_u8)
    io.write_byte(0x7d_u8) # EMPTY_DICT (root)
    io.write_byte(0x28_u8) # MARK
    pickle_key(io, "k")
    pickle_global(io, "ansible.module_utils._internal._datatag", "_AnsibleTagsMapping")
    io.write_byte(0x29_u8) # EMPTY_TUPLE
    io.write_byte(0x81_u8) # NEWOBJ
    io.write_byte(0x75_u8) # SETITEMS
    io.write_byte(0x2e_u8) # STOP

    assert_raises_message(Krikri::FactCache::Pickle::Unsupported, "pickle tag object leaked into the facts") do
      Krikri::FactCache::Pickle.decode(io.to_slice)
    end
  end

  it "refuses a memo-shared DAG that would make the tree walk exponential" do
    # d0 = {}; d(i) = {'a': d(i-1), 'b': d(i-1)} - 2**depth node visits from
    # fewer than a thousand bytes.
    io = IO::Memory.new
    io.write_byte(0x80_u8)
    io.write_byte(0x02_u8)
    io.write_byte(0x7d_u8) # EMPTY_DICT
    io.write_byte(0x71_u8) # BINPUT 0
    io.write_byte(0x00_u8)
    depth = 26
    1.upto(depth) do |level|
      io.write_byte(0x7d_u8) # EMPTY_DICT
      io.write_byte(0x71_u8) # BINPUT level
      io.write_byte(level.to_u8)
      io.write_byte(0x28_u8) # MARK
      pickle_key(io, "a")
      io.write_byte(0x68_u8) # BINGET level-1
      io.write_byte((level - 1).to_u8)
      pickle_key(io, "b")
      io.write_byte(0x68_u8)
      io.write_byte((level - 1).to_u8)
      io.write_byte(0x75_u8) # SETITEMS
    end
    io.write_byte(0x68_u8) # BINGET depth
    io.write_byte(depth.to_u8)
    io.write_byte(0x2e_u8) # STOP

    assert_raises_message(Krikri::FactCache::Pickle::Unsupported, "pickle graph too large") do
      Krikri::FactCache::Pickle.decode(io.to_slice)
    end
  end
end

describe "Krikri::FactCache path naming, timeout and write safety" do
  # exclusive!, not serial!: this test rewrites ENV["HOME"] for the ~/$VAR
  # expansion case, and concurrently spawned krikri-playbook children
  # inherit the process environment, so a merely serial window could hand
  # another test's child a bogus HOME.
  exclusive!

  before_each do
    @dir = PluginSpecHelper.tmp_path("fact-cache-paths")
    Dir.mkdir_p(cache_dir)
    ENV["ANSIBLE_CACHE_PLUGIN"] = "community.general.pickle"
    ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = cache_dir
    ENV.delete("ANSIBLE_CACHE_PLUGIN_PREFIX")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_TIMEOUT")
  end

  after_each do
    ENV.delete("ANSIBLE_CACHE_PLUGIN")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_CONNECTION")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_PREFIX")
    ENV.delete("ANSIBLE_CACHE_PLUGIN_TIMEOUT")
    FileUtils.rm_rf(cache_dir)
  end

  private def cache_dir : String
    @dir.as(String)
  end

  it "names files the way ansible's _sanitize_key does" do
    # Captured live from ansible-core 2.21.6: a key carrying a path-ish
    # character is replaced by sha256(key) truncated to max(len(key), 12).
    {"a/b" => "c14cddc033f6", ".." => "5ec1f7e700f3", "<x>" => "22305fe27eeb", "|y" => "3ee3a991a02f"}.each do |key, expected|
      Krikri::FactCache.write(key, {"k" => JSON::Any.new("v")})
      File.exists?(File.join(cache_dir, expected)).must_equal(true)
      Krikri::FactCache.read(key).try(&.["k"]?).try(&.as_s).must_equal("v")
    end
    # A dot in a normal host name is not a path hazard for ansible.
    Krikri::FactCache.write("plain.host", {"k" => JSON::Any.new("v")})
    File.exists?(File.join(cache_dir, "plain.host")).must_equal(true)
  end

  it "prepends ANSIBLE_CACHE_PLUGIN_PREFIX like both ansible file plugins" do
    ENV["ANSIBLE_CACHE_PLUGIN_PREFIX"] = "pfx-"
    Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
    Dir.children(cache_dir).must_equal(["pfx-h"])
  end

  it "expands ~ and $VAR in the connection path like ansible does" do
    saved_home = ENV["HOME"]?
    home = File.join(cache_dir, "fakehome")
    Dir.mkdir_p(home)
    ENV["HOME"] = home
    begin
      ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = "~/cache-1838"
      Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
      File.exists?(File.join(home, "cache-1838", "h")).must_equal(true)

      ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = "${HOME}/cache-1838b"
      Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
      File.exists?(File.join(home, "cache-1838b", "h")).must_equal(true)

      # An unset variable is left alone, like os.path.expandvars.
      ENV.delete("KRIKRI_SURELY_UNSET_VAR")
      ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = File.join(cache_dir, "$KRIKRI_SURELY_UNSET_VAR", "x")
      Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
      File.exists?(File.join(cache_dir, "$KRIKRI_SURELY_UNSET_VAR", "x", "h")).must_equal(true)
    ensure
      ENV["HOME"] = saved_home if saved_home
      ENV.delete("HOME") unless saved_home
    end
  end

  it "honors a fractional ANSIBLE_CACHE_PLUGIN_TIMEOUT" do
    ENV["ANSIBLE_CACHE_PLUGIN_TIMEOUT"] = "0.5"
    Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
    Krikri::FactCache.read("h").try(&.["k"]?).must_equal(JSON::Any.new("v"))

    path = File.join(cache_dir, "h")
    old = Time.utc - 2.seconds
    File.utime(old, old, path)
    Krikri::FactCache.read("h").must_be_nil
  end

  it "treats a negative ANSIBLE_CACHE_PLUGIN_TIMEOUT as always expired" do
    ENV["ANSIBLE_CACHE_PLUGIN_TIMEOUT"] = "-5"
    Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
    Krikri::FactCache.read("h").must_be_nil
  end

  it "treats an empty expanded connection (~ with no HOME) as unset" do
    saved = ENV["HOME"]?
    ENV["HOME"] = ""
    begin
      ENV["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = "~"
      Krikri::FactCache.enabled?.must_equal(false)
    ensure
      ENV["HOME"] = saved if saved
      ENV.delete("HOME") unless saved
    end
  end

  it "writes owner-only and keeps the mode across the atomic rename" do
    Krikri::FactCache.write("h", {"k" => JSON::Any.new("v")})
    (File.info(File.join(cache_dir, "h")).permissions.value & 0o777).must_equal(0o600)
    Dir.children(cache_dir).must_equal(["h"])
  end

  it "leaves a pickle it cannot read untouched but replaces plain junk" do
    foreign = Bytes[0x80, 0x02, 0x63, 0x6f, 0x73, 0x0a, 0x73, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x0a, 0x2e]
    File.write(File.join(cache_dir, "foreign"), foreign)
    Krikri::FactCache.write("foreign", {"k" => JSON::Any.new("new")})
    File.read(File.join(cache_dir, "foreign")).to_slice.must_equal(foreign)

    File.write(File.join(cache_dir, "junk"), %({"jsonfile": "leftover"}))
    Krikri::FactCache.write("junk", {"k" => JSON::Any.new("new")})
    Krikri::FactCache.read("junk").try(&.["k"]?).must_equal(JSON::Any.new("new"))

    # A truncated pickle (not an unsupported construct) is replaced too, so
    # a bad entry heals instead of wedging the host.
    File.write(File.join(cache_dir, "short"), Bytes[0x80, 0x02])
    Krikri::FactCache.write("short", {"k" => JSON::Any.new("new")})
    Krikri::FactCache.read("short").try(&.["k"]?).must_equal(JSON::Any.new("new"))
  end
end

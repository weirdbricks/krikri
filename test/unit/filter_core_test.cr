require "../minitest_helper"
require "../../src/krikri/variable_substitutor/filter_core"

# The ONE shared implementation for the string/path filter family (was
# two independently-maintained copies - Crinja-side in jinja_filters.cr,
# JSON::Any-side in filter_engine.cr - with regex_replace already
# drifted: the Crinja copy used Crystal's native gsub backref expansion,
# the engine copy a hand-rolled `\\d` substitution).
describe Krikri::VariableSubstitutor::FilterCore do
  it "regex_replace substitutes every match with backreferences" do
    Krikri::VariableSubstitutor::FilterCore.regex_replace("v1.12.1", "^v?([0-9.]+)$", "\\1")
      .must_equal("1.12.1")
    Krikri::VariableSubstitutor::FilterCore.regex_replace("a-b-c", "-", "+")
      .must_equal("a+b+c")
  end

  it "regex_replace renders a non-participating group as empty" do
    Krikri::VariableSubstitutor::FilterCore.regex_replace("abc", "(x)|(abc)", "\\1\\2")
      .must_equal("abc")
  end

  it "regex_replace honors ignorecase/multiline options (Python re.I/re.M, NOT dotall)" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.regex_replace("a1\nb2", "^b(\\d)", "X\\1", Regex::Options::MULTILINE_ONLY)
      .must_equal("a1\nX2")
    # Python's re.M only moves ^/$ to line boundaries; `.` must NOT cross
    # newlines (Crystal's Regex::Options::MULTILINE would imply DOTALL).
    core.regex_replace("1\nb2", "1.b", "Z", Regex::Options::MULTILINE_ONLY)
      .must_equal("1\nb2")
    core.regex_replace("HELLO", "hello", "X", Regex::Options::IGNORE_CASE)
      .must_equal("X")
  end

  it "regex_escape escapes special characters" do
    Krikri::VariableSubstitutor::FilterCore.regex_escape("a.b*c")
      .must_equal(Regex.escape("a.b*c"))
  end

  it "normpath collapses . and .. without absolutizing" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.normpath("/a/./b//c").must_equal("/a/b/c")
    core.normpath("a/../b").must_equal("b")
    core.normpath("../a").must_equal("../a")
    core.normpath("").must_equal(".")
  end

  it "splitext splits root and extension Python-style" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.splitext("/etc/nginx/nginx.conf").must_equal({"/etc/nginx/nginx", ".conf"})
    core.splitext("/etc/nginx/nginx").must_equal({"/etc/nginx/nginx", ""})
  end

  it "commonpath finds the longest shared SEGMENT prefix" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.commonpath(["/var/log/nginx", "/var/log/redis"]).must_equal("/var/log")
    core.commonpath(["/var/log/a", "/var/lib/b"]).must_equal("/var")
    core.commonpath([] of String).must_equal("")
    # not a character prefix: "common" != "commondir"
    # not a character prefix: "common" != "commondir" -> only the
    # root segment is shared
    core.commonpath(["/common", "/commondir"]).must_equal("/")
  end

  it "path_join resets on absolute components" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.path_join(["a", "b", "c"]).must_equal("a/b/c")
    core.path_join(["a", "/etc", "c"]).must_equal("/etc/c")
  end

  it "expandvars leaves unset variables as-is" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.expandvars("no vars here").must_equal("no vars here")
    # $KRIKRI_SURELY_UNSET must survive untouched (Python's own behavior)
    core.expandvars("$KRIKRI_SURELY_UNSET/x").must_equal("$KRIKRI_SURELY_UNSET/x")
    core.expandvars("${KRIKRI_SURELY_UNSET}/x").must_equal("${KRIKRI_SURELY_UNSET}/x")
  end

  it "type_debug maps to Python type names" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.type_debug(JSON.parse("[1,2]")).must_equal("list")
    core.type_debug(JSON.parse(%({"a": 1}))).must_equal("dict")
    core.type_debug(JSON.parse("3")).must_equal("int")
    core.type_debug(JSON.parse("3.5")).must_equal("float")
    core.type_debug(JSON.parse("true")).must_equal("bool")
    core.type_debug(JSON.parse("null")).must_equal("NoneType")
    core.type_debug(JSON.parse(%("s"))).must_equal("str")
  end

  describe "family 2: data/hash/encoding" do
    private def core
      Krikri::VariableSubstitutor::FilterCore
    end

    it "hash defaults to sha1 and supports the hashlib algorithm set" do
      core.hash("abc", "sha1").must_equal("a9993e364706816aba3e25717850c26c9cd0d89d")
      core.hash("abc", "sha256").must_equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      core.hash("abc", "SHA512").must_equal(core.hash("abc", "sha512"))
      assert_raises_message(Exception, "unsupported algorithm") { core.hash("abc", "nope") }
    end

    it "checksum/md5/sha1 produce known hex digests" do
      core.checksum("abc").must_equal("a9993e364706816aba3e25717850c26c9cd0d89d")
      core.md5("abc").must_equal("900150983cd24fb0d6963f7d28e17f72")
      core.sha1("abc").must_equal("a9993e364706816aba3e25717850c26c9cd0d89d")
    end

    # Every vector below is a real ansible-core 2.21.6 run on this host:
    # 2.21 hashes through libxcrypt, which re-encodes a user-supplied salt
    # with crypt's base64 ("mysalt" -> "hZrQ") and clamps rounds instead of
    # rejecting out-of-range ones.
    it "password_hash produces a salted crypt(3) hash of the right scheme" do
      result = core.password_hash("s3cret", "sha512", "salt1234")
      expect(str_starts_with?(result, "$6$rounds=656000$")).must_equal(true)
      # bcrypt is part of the 2.21 backend (it was passlib-only before).
      expect(str_starts_with?(core.password_hash("x", "bcrypt", "abcdefghijklmnopqrstuv"), "$2b$12$"))
        .must_equal(true)
    end

    it "password_hash omits the rounds marker only at exactly 5000" do
      core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(5000i64))
        .must_equal("$6$hZrQ$BbQdhpRdjnqFDPw4p5v843JM4Oin5nWjLVS6VPOVDpRbNui5p79Eip4Qdnht7WtEkbTE6JEU1sabIxihLQw9u0")
      core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(10000i64))
        .must_equal("$6$rounds=10000$hZrQ$/caPJpw5Tj89xY2U1yA7CtVdIcI4dUAvUr1ObcI40ZlzgT7Z/eur5OUBN5jM6M9sYG70BY.VqurKBTUF7wECL.")
      core.password_hash("hello", "sha256", "mysalt", rounds: JSON::Any.new(5000i64))
        .must_equal("$5$hZrQ$D1kKBg1ooKs2nIYKWen6hfMT0g5.QINPDEhORfmiVa8")
      core.password_hash("hello", "sha256", "mysalt", rounds: JSON::Any.new(535000i64))
        .must_equal("$5$rounds=535000$hZrQ$FmC/9WaSUo2gDz6P0EwAlh7lqHucptGCb6JFpEqMAk5")
    end

    it "password_hash skips falsy rounds like python truthiness" do
      default = core.password_hash("hello", "sha512", "mysalt")
      default.must_equal("$6$rounds=656000$hZrQ$pHtC7xLocYGK7GZJsMh2WFqgHywV.q6jHM3uHVKbOx9zJzm7QViLInfJ12Ji3j4tIiAhprbEFUW.0DhUaBSAp1")
      core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(0i64)).must_equal(default)
      core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(false)).must_equal(default)
      core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new("")).must_equal(default)
      # rounds=true counts as 1, which libxcrypt clamps up to its floor
      core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(true))
        .must_equal("$6$rounds=1000$hZrQ$VH6SoAIfITskeipS69u62BetwLydNb9B1ssl8uTUdxKrqNUGn0xitf4VcHtC3zb1m.Tw3yCLTQjStTcw5s1/k1")
    end

    it "password_hash rejects non-integer rounds with libxcrypt's binding errors" do
      assert_raises_message(Exception,
        "argument 2: TypeError: 'str' object cannot be interpreted as an integer") do
        core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new("10000"))
      end
      assert_raises_message(Exception,
        "argument 2: TypeError: 'float' object cannot be interpreted as an integer") do
        core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(10000.5))
      end
    end

    it "password_hash lets libxcrypt clamp rounds instead of rejecting them" do
      expect(str_starts_with?(core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(999i64)),
        "$6$rounds=1000$")).must_equal(true)
    end

    # The upper clamp only shows up at rounds >= 1e9, and sha512-crypt's cost is
    # linear in rounds: a real derivation there takes ~4 minutes of one core, which
    # made this ONE test the whole suite's critical path (scripts/minitest_stats.sh
    # ranked it first, far above everything else). Opt in to check it for real.
    it "password_hash clamps rounds above libxcrypt's maximum" do
      skip("set KRIKRI_SLOW_TESTS=1; a 1e9-round sha512-crypt costs ~4 minutes") unless ENV["KRIKRI_SLOW_TESTS"]? == "1"
      expect(str_starts_with?(core.password_hash("hello", "sha512", "mysalt", rounds: JSON::Any.new(1000000000i64)),
        "$6$rounds=999999999$")).must_equal(true)
    end

    it "password_hash's salt_size only sizes the generated salt" do
      # an explicit salt is re-encoded, never truncated
      core.password_hash("hello", "sha512", "mysalt", salt_size: JSON::Any.new(8i64))
        .must_equal(core.password_hash("hello", "sha512", "mysalt"))
      # generated salt length follows salt_size (default-rounds marker
      # is 17 chars: $6$ + rounds=656000 + $ + salt + $ + 86 hash chars)
      core.password_hash("hello", "sha512", salt_size: JSON::Any.new(8i64)).size.must_equal(112)
      core.password_hash("hello", "sha512").size.must_equal(120)
      # md5's own cap is 8; its generated salt defaults to 8, not 16
      core.password_hash("hello", "md5").size.must_equal(34)
      core.password_hash("hello", "md5", salt_size: JSON::Any.new(4i64)).size.must_equal(30)
    end

    it "password_hash validates salt_size type and range, salt length and charset" do
      assert_raises_message(Exception, "salt_size must be an integer") do
        core.password_hash("hello", "sha512", "mysalt", salt_size: JSON::Any.new("x"))
      end
      assert_raises_message(Exception, "invalid salt size supplied (32), expected at most 16") do
        core.password_hash("hello", "sha512", "mysalt", salt_size: JSON::Any.new(32i64))
      end
      assert_raises_message(Exception, "invalid salt size supplied (29), expected at most 16") do
        core.password_hash("hello", "sha512", "longsaltvalue0123456789abcdef")
      end
      assert_raises_message(Exception, "invalid salt size supplied (20), expected at most 8") do
        core.password_hash("hello", "md5", "longsaltvalue0123456")
      end
      assert_raises_message(Exception, "invalid characters in salt") do
        core.password_hash("hello", "sha512", "sal~t")
      end
    end

    it "password_hash is case-sensitive in hashtype and md5 takes no rounds" do
      assert_raises_message(Exception,
        "SHA512 is not in the list of supported passlib algorithms: md5, blowfish, sha256, sha512") do
        core.password_hash("hello", "SHA512", "mysalt")
      end
      # libxcrypt's $1$ gensalt refuses a rounds count entirely
      assert_raises_message(Exception,
        "Failed to generate salt for 'md5_crypt' algorithm: crypt_gensalt failed: unable to generate salt") do
        core.password_hash("hello", "md5", "mysalt", rounds: JSON::Any.new(5000i64))
      end
    end

    it "to_uuid is deterministic (Ansible's own namespace)" do
      core.to_uuid("app1").must_equal(core.to_uuid("app1"))
      core.to_uuid("app1").wont_equal(core.to_uuid("app2"))
    end

    it "b64 round-trips and b64decode raises on invalid input" do
      encoded = core.b64encode("hello there")
      core.b64decode(encoded).must_equal("hello there")
      assert_raises_message(Exception, "invalid base64") { core.b64decode("!!!not-base64!!!") }
    end

    it "from_json raises on invalid input" do
      core.from_json(%({"a": 1}))["a"].as_i.must_equal(1)
      assert_raises_message(Exception, "invalid JSON") { core.from_json("{nope}") }
    end

    it "from_yaml passes non-string values through unchanged (Ansible behavior)" do
      list_value = JSON.parse("[1,2]")
      core.from_yaml(list_value).must_equal(list_value)
      str_value = JSON.parse("\"a: 1\\nb: 2\"")
      result = core.from_yaml(str_value)
      result["b"].as_i.must_equal(2)
      assert_raises_message(Exception, "invalid YAML") { core.from_yaml(JSON.parse("\"%nope: [\"")) }
    end

    it "to_json uses Python json.dumps separators" do
      value = JSON.parse(%({"a": 1, "b": [1, 2]}))
      core.to_json(value).must_equal(%({"a": 1, "b": [1, 2]}))
    end

    it "to_nice_json sorts keys by default" do
      value = JSON.parse(%({"b": 1, "a": {"d": 2, "c": 3}}))
      result = core.to_nice_json(value)
      first_a = result.index("\"a\"")
      first_b = result.index("\"b\"")
      first_a.wont_be_nil
      first_b.wont_be_nil
      first_a.must_equal(first_a) # nil-guard: both indexes must exist
      expect((first_a.as(Int32)) < (first_b.as(Int32))).must_equal(true)
    end

    it "to_yaml sorts keys and strips the leading document marker" do
      value = JSON.parse(%({"b": 1, "a": 2}))
      yaml_text = core.to_yaml(value)
      expect(str_starts_with?(yaml_text, "---")).must_equal(false)
      first_a = yaml_text.index("a: 2")
      first_b = yaml_text.index("b: 1")
      first_a.wont_be_nil
      first_b.wont_be_nil
      first_a.must_equal(first_a) # nil-guard: both indexes must exist
      expect((first_a.as(Int32)) < (first_b.as(Int32))).must_equal(true)
    end
  end

  describe "family 3: set operations" do
    private def core
      Krikri::VariableSubstitutor::FilterCore
    end

    private def a
      JSON.parse(%([1, 2, 3]))
    end

    private def b
      JSON.parse(%([3, 4]))
    end

    private def list
      JSON.parse(%([{"n": 1}, {"n": 2}]))
    end

    it "union dedupes across and within both lists, first-seen order" do
      core.union(a.as_a, b.as_a).map(&.as_i).must_equal([1, 2, 3, 4])
      core.union(a.as_a, a.as_a).map(&.as_i).must_equal([1, 2, 3])
    end

    it "intersect takes value-side order, deduplicated" do
      core.intersect(a.as_a, b.as_a).map(&.as_i).must_equal([3])
      core.intersect(JSON.parse(%([2, 2, 3])).as_a, JSON.parse(%([2, 3])).as_a).map(&.as_i).must_equal([2, 3])
    end

    it "difference removes other's elements from value" do
      core.difference(a.as_a, b.as_a).map(&.as_i).must_equal([1, 2])
      core.difference(b.as_a, a.as_a).map(&.as_i).must_equal([4])
    end

    it "symmetric_difference is elements in exactly one list" do
      core.symmetric_difference(a.as_a, b.as_a).map(&.as_i).must_equal([1, 2, 4])
    end

    it "set ops compare nested structures structurally" do
      other = JSON.parse(%([{"n": 1}]))
      core.intersect(list.as_a, other.as_a).map(&.to_json).must_equal([JSON.parse(%({"n": 1})).to_json])
      core.difference(list.as_a, other.as_a).map(&.to_json).must_equal([JSON.parse(%({"n": 2})).to_json])
    end

    it "set filters treat a dict operand as its keys" do
      packages = JSON.parse(%({"podman": ["5.0"], "podman-plugins": ["5.0"]}))
      core.to_set_items(packages).map(&.as_s).must_equal(["podman", "podman-plugins"])
      core.difference(core.to_set_items(a), core.to_set_items(packages)).map(&.raw).must_equal([1, 2, 3])
      core.difference(core.to_set_items(packages), core.to_set_items(b)).map(&.as_s).must_equal(["podman", "podman-plugins"])
      core.intersect(core.to_set_items(a), core.to_set_items(packages)).must_equal([] of JSON::Any)
      core.union(core.to_set_items(packages), core.to_set_items(b)).map(&.raw).must_equal(["podman", "podman-plugins", 3, 4])
      core.symmetric_difference(core.to_set_items(packages), core.to_set_items(b)).map(&.raw)
        .must_equal(["podman", "podman-plugins", 3, 4])
    end
  end

  describe "family 4: byte formatting" do
    private def core
      Krikri::VariableSubstitutor::FilterCore
    end

    it "human_readable formats 1024-based sizes" do
      core.format_human_readable(1_i64, false).must_equal("1 Bytes")
      core.format_human_readable(1024_i64, false).must_equal("1.00 KB")
      core.format_human_readable(1_i64 * 1024 * 1024 * 1024, false).must_equal("1.00 GB")
      core.format_human_readable(1536_i64, false).must_equal("1.50 KB")
    end

    it "human_readable isbits multiplies by 8 and uses bit suffixes" do
      core.format_human_readable(1_i64, true).must_equal("8 bits")
      core.format_human_readable(1024_i64, true).must_equal("8.00 Kb")
    end

    it "human_to_bytes parses unit suffixes case-insensitively" do
      core.parse_human_to_bytes("1").must_equal(1)
      core.parse_human_to_bytes("10GB").must_equal(10_i64 * 1024 ** 3)
      core.parse_human_to_bytes("1.5 MB").must_equal(1572864)
      core.parse_human_to_bytes("1KB").must_equal(1024)
      # unparseable input falls back to a bare to_i64
      core.parse_human_to_bytes("abc").must_equal(0)
    end

    it "human_to_bytes is the inverse of human_readable" do
      core.parse_human_to_bytes(core.format_human_readable(1536_i64, false)).must_equal(1536)
    end
  end

  describe "netmask_to_cidr" do
    private def core
      Krikri::VariableSubstitutor::FilterCore
    end

    # Regression (kyl191.openvpn, 120-author kata round):
    # community.general's netmask_to_cidr filter was entirely
    # unimplemented ("No filter named 'netmask_to_cidr'"), reached via
    # the role's own openvpn_server_netmask_cidr default.
    it "converts a contiguous dotted-decimal netmask to its CIDR prefix length" do
      core.netmask_to_cidr("255.255.255.0").must_equal(24)
      core.netmask_to_cidr("255.255.0.0").must_equal(16)
      core.netmask_to_cidr("255.255.255.255").must_equal(32)
      core.netmask_to_cidr("0.0.0.0").must_equal(0)
      core.netmask_to_cidr("255.255.255.128").must_equal(25)
    end

    it "raises on a non-contiguous mask" do
      assert_raises_message(Exception, /not a valid netmask/) do
        core.netmask_to_cidr("255.0.255.0")
      end
    end

    it "raises on a malformed string" do
      assert_raises_message(Exception, /not a valid netmask/) do
        core.netmask_to_cidr("not.an.ip.address")
      end
      assert_raises_message(Exception, /not a valid netmask/) do
        core.netmask_to_cidr("255.255.255")
      end
    end
  end
end

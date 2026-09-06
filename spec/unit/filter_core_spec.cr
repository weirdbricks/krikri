require "../spec_helper"
require "../../src/krikri/variable_substitutor/filter_core"

# The ONE shared implementation for the string/path filter family (was
# two independently-maintained copies - Crinja-side in jinja_filters.cr,
# JSON::Any-side in filter_engine.cr - with regex_replace already
# drifted: the Crinja copy used Crystal's native gsub backref expansion,
# the engine copy a hand-rolled `\\d` substitution).
describe Krikri::VariableSubstitutor::FilterCore do
  it "regex_replace substitutes every match with backreferences" do
    Krikri::VariableSubstitutor::FilterCore.regex_replace("v1.12.1", "^v?([0-9.]+)$", "\\1")
      .should eq("1.12.1")
    Krikri::VariableSubstitutor::FilterCore.regex_replace("a-b-c", "-", "+")
      .should eq("a+b+c")
  end

  it "regex_replace renders a non-participating group as empty" do
    Krikri::VariableSubstitutor::FilterCore.regex_replace("abc", "(x)|(abc)", "\\1\\2")
      .should eq("abc")
  end

  it "regex_escape escapes special characters" do
    Krikri::VariableSubstitutor::FilterCore.regex_escape("a.b*c")
      .should eq(Regex.escape("a.b*c"))
  end

  it "normpath collapses . and .. without absolutizing" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.normpath("/a/./b//c").should eq("/a/b/c")
    core.normpath("a/../b").should eq("b")
    core.normpath("../a").should eq("../a")
    core.normpath("").should eq(".")
  end

  it "splitext splits root and extension Python-style" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.splitext("/etc/nginx/nginx.conf").should eq({"/etc/nginx/nginx", ".conf"})
    core.splitext("/etc/nginx/nginx").should eq({"/etc/nginx/nginx", ""})
  end

  it "commonpath finds the longest shared SEGMENT prefix" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.commonpath(["/var/log/nginx", "/var/log/redis"]).should eq("/var/log")
    core.commonpath(["/var/log/a", "/var/lib/b"]).should eq("/var")
    core.commonpath([] of String).should eq("")
    # not a character prefix: "common" != "commondir"
    # not a character prefix: "common" != "commondir" -> only the
    # root segment is shared
    core.commonpath(["/common", "/commondir"]).should eq("/")
  end

  it "path_join resets on absolute components" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.path_join(["a", "b", "c"]).should eq("a/b/c")
    core.path_join(["a", "/etc", "c"]).should eq("/etc/c")
  end

  it "expandvars leaves unset variables as-is" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.expandvars("no vars here").should eq("no vars here")
    # $KRIKRI_SURELY_UNSET must survive untouched (Python's own behavior)
    core.expandvars("$KRIKRI_SURELY_UNSET/x").should eq("$KRIKRI_SURELY_UNSET/x")
    core.expandvars("${KRIKRI_SURELY_UNSET}/x").should eq("${KRIKRI_SURELY_UNSET}/x")
  end

  it "type_debug maps to Python type names" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.type_debug(JSON.parse("[1,2]")).should eq("list")
    core.type_debug(JSON.parse(%({"a": 1}))).should eq("dict")
    core.type_debug(JSON.parse("3")).should eq("int")
    core.type_debug(JSON.parse("3.5")).should eq("float")
    core.type_debug(JSON.parse("true")).should eq("bool")
    core.type_debug(JSON.parse("null")).should eq("NoneType")
    core.type_debug(JSON.parse(%("s"))).should eq("str")
  end

  describe "family 2: data/hash/encoding" do
    core = Krikri::VariableSubstitutor::FilterCore

    it "hash defaults to sha1 and supports the hashlib algorithm set" do
      core.hash("abc", "sha1").should eq("a9993e364706816aba3e25717850c26c9cd0d89d")
      core.hash("abc", "sha256").should eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      core.hash("abc", "SHA512").should eq(core.hash("abc", "sha512"))
      expect_raises(Exception, "unsupported algorithm") { core.hash("abc", "nope") }
    end

    it "checksum/md5/sha1 produce known hex digests" do
      core.checksum("abc").should eq("a9993e364706816aba3e25717850c26c9cd0d89d")
      core.md5("abc").should eq("900150983cd24fb0d6963f7d28e17f72")
      core.sha1("abc").should eq("a9993e364706816aba3e25717850c26c9cd0d89d")
    end

    it "password_hash produces a salted crypt(3) hash of the right scheme" do
      result = core.password_hash("s3cret", "sha512", "salt1234")
      result.should start_with("$6$salt1234$")
      expect_raises(Exception, "unsupported hashtype") { core.password_hash("x", "bcrypt") }
    end

    it "to_uuid is deterministic (Ansible's own namespace)" do
      core.to_uuid("app1").should eq(core.to_uuid("app1"))
      core.to_uuid("app1").should_not eq(core.to_uuid("app2"))
    end

    it "b64 round-trips and b64decode raises on invalid input" do
      encoded = core.b64encode("hello there")
      core.b64decode(encoded).should eq("hello there")
      expect_raises(Exception, "invalid base64") { core.b64decode("!!!not-base64!!!") }
    end

    it "from_json raises on invalid input" do
      core.from_json(%({"a": 1}))["a"].as_i.should eq(1)
      expect_raises(Exception, "invalid JSON") { core.from_json("{nope}") }
    end

    it "from_yaml passes non-string values through unchanged (real Ansible behavior)" do
      list_value = JSON.parse("[1,2]")
      core.from_yaml(list_value).should eq(list_value)
      str_value = JSON.parse("\"a: 1\\nb: 2\"")
      result = core.from_yaml(str_value)
      result["b"].as_i.should eq(2)
      expect_raises(Exception, "invalid YAML") { core.from_yaml(JSON.parse("\"%nope: [\"")) }
    end

    it "to_json uses Python json.dumps separators" do
      value = JSON.parse(%({"a": 1, "b": [1, 2]}))
      core.to_json(value).should eq(%({"a": 1, "b": [1, 2]}))
    end

    it "to_nice_json sorts keys by default" do
      value = JSON.parse(%({"b": 1, "a": {"d": 2, "c": 3}}))
      result = core.to_nice_json(value)
      first_a = result.index("\"a\"")
      first_b = result.index("\"b\"")
      first_a.should_not be_nil
      first_b.should_not be_nil
      first_a.should eq(first_a) # nil-guard: both indexes must exist
      (first_a.as(Int32)).should be < (first_b.as(Int32))
    end

    it "to_yaml sorts keys and strips the leading document marker" do
      value = JSON.parse(%({"b": 1, "a": 2}))
      out = core.to_yaml(value)
      out.should_not start_with("---")
      first_a = out.index("a: 2")
      first_b = out.index("b: 1")
      first_a.should_not be_nil
      first_b.should_not be_nil
      first_a.should eq(first_a) # nil-guard: both indexes must exist
      (first_a.as(Int32)).should be < (first_b.as(Int32))
    end
  end

  describe "family 3: set operations" do
    core = Krikri::VariableSubstitutor::FilterCore
    a = JSON.parse(%([1, 2, 3]))
    b = JSON.parse(%([3, 4]))
    list = JSON.parse(%([{"n": 1}, {"n": 2}]))

    it "union dedupes across and within both lists, first-seen order" do
      core.union(a.as_a, b.as_a).map(&.as_i).should eq([1, 2, 3, 4])
      core.union(a.as_a, a.as_a).map(&.as_i).should eq([1, 2, 3])
    end

    it "intersect takes value-side order, deduplicated" do
      core.intersect(a.as_a, b.as_a).map(&.as_i).should eq([3])
      core.intersect(JSON.parse(%([2, 2, 3])).as_a, JSON.parse(%([2, 3])).as_a).map(&.as_i).should eq([2, 3])
    end

    it "difference removes other's elements from value" do
      core.difference(a.as_a, b.as_a).map(&.as_i).should eq([1, 2])
      core.difference(b.as_a, a.as_a).map(&.as_i).should eq([4])
    end

    it "symmetric_difference is elements in exactly one list" do
      core.symmetric_difference(a.as_a, b.as_a).map(&.as_i).should eq([1, 2, 4])
    end

    it "set ops compare nested structures structurally" do
      other = JSON.parse(%([{"n": 1}]))
      core.intersect(list.as_a, other.as_a).map(&.to_json).should eq([JSON.parse(%({"n": 1})).to_json])
      core.difference(list.as_a, other.as_a).map(&.to_json).should eq([JSON.parse(%({"n": 2})).to_json])
    end
  end

  describe "family 4: byte formatting" do
    core = Krikri::VariableSubstitutor::FilterCore

    it "human_readable formats 1024-based sizes" do
      core.format_human_readable(1_i64, false).should eq("1 Bytes")
      core.format_human_readable(1024_i64, false).should eq("1.00 KB")
      core.format_human_readable(1_i64 * 1024 * 1024 * 1024, false).should eq("1.00 GB")
      core.format_human_readable(1536_i64, false).should eq("1.50 KB")
    end

    it "human_readable isbits multiplies by 8 and uses bit suffixes" do
      core.format_human_readable(1_i64, true).should eq("8 bits")
      core.format_human_readable(1024_i64, true).should eq("8.00 Kb")
    end

    it "human_to_bytes parses unit suffixes case-insensitively" do
      core.parse_human_to_bytes("1").should eq(1)
      core.parse_human_to_bytes("10GB").should eq(10_i64 * 1024 ** 3)
      core.parse_human_to_bytes("1.5 MB").should eq(1572864)
      core.parse_human_to_bytes("1KB").should eq(1024)
      # unparseable input falls back to a bare to_i64
      core.parse_human_to_bytes("abc").should eq(0)
    end

    it "human_to_bytes is the inverse of human_readable" do
      core.parse_human_to_bytes(core.format_human_readable(1536_i64, false)).should eq(1536)
    end
  end

  describe "netmask_to_cidr" do
    core = Krikri::VariableSubstitutor::FilterCore

    # Regression (kyl191.openvpn, 120-author kata round):
    # community.general's netmask_to_cidr filter was entirely
    # unimplemented ("No filter named 'netmask_to_cidr'"), reached via
    # the role's own openvpn_server_netmask_cidr default.
    it "converts a contiguous dotted-decimal netmask to its CIDR prefix length" do
      core.netmask_to_cidr("255.255.255.0").should eq(24)
      core.netmask_to_cidr("255.255.0.0").should eq(16)
      core.netmask_to_cidr("255.255.255.255").should eq(32)
      core.netmask_to_cidr("0.0.0.0").should eq(0)
      core.netmask_to_cidr("255.255.255.128").should eq(25)
    end

    it "raises on a non-contiguous mask" do
      expect_raises(Exception, /not a valid netmask/) do
        core.netmask_to_cidr("255.0.255.0")
      end
    end

    it "raises on a malformed string" do
      expect_raises(Exception, /not a valid netmask/) do
        core.netmask_to_cidr("not.an.ip.address")
      end
      expect_raises(Exception, /not a valid netmask/) do
        core.netmask_to_cidr("255.255.255")
      end
    end
  end
end

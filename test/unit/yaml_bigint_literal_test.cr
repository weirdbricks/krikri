require "../minitest_helper"
require "yaml"
require "json"
require "big"
require "../../src/krikri/yaml_bigint"

# PyYAML resolves an unquoted YAML integer scalar into a Python int -
# arbitrary precision, so a literal wider than 64 bits keeps every digit
# and prints back exactly as written (`is integer` true). Crystal's core
# schema resolves through Int64 and falls through to Float64 on overflow
# (digits silently rounded away), and leaves wide hex/octal literals as
# plain strings. krikri resolves these literals to Krikri's bigint
# sentinel string instead (see src/krikri/yaml_bigint.cr) so the digits
# survive the whole pipeline the way Ansible's Python ints do.

describe "YAML unquoted wide-integer scalar resolution (yaml_bigint_literal_test.cr)" do
  it "resolves a decimal literal wider than Int64 to the bigint sentinel" do
    doc = YAML.parse("n: 123456789012345678901234567890")
    doc["n"].raw.must_equal(Krikri.bigint_sentinel("123456789012345678901234567890"))
  end

  it "resolves a negative literal wider than Int64 to a signed sentinel" do
    doc = YAML.parse("n: -123456789012345678901234567890")
    doc["n"].raw.must_equal(Krikri.bigint_sentinel("-123456789012345678901234567890"))
  end

  it "resolves an underscored literal wider than Int64 to a bare-digits sentinel" do
    doc = YAML.parse("n: 1_000_000_000_000_000_000_000")
    doc["n"].raw.must_equal(Krikri.bigint_sentinel("1000000000000000000000"))
  end

  it "resolves a hex literal wider than Int64 to its decimal sentinel" do
    doc = YAML.parse("n: 0x1234567890abcdef1234")
    expected = BigInt.new("1234567890abcdef1234", 16).to_s
    doc["n"].raw.must_equal(Krikri.bigint_sentinel(expected))
  end

  it "keeps the sign of a negative hex literal wider than Int64" do
    doc = YAML.parse("n: -0x1234567890abcdef1234")
    expected = (-BigInt.new("1234567890abcdef1234", 16)).to_s
    doc["n"].raw.must_equal(Krikri.bigint_sentinel(expected))
  end

  it "keeps an Int64-fitting literal a real Int64" do
    doc = YAML.parse("n: 9007199254740993")
    doc["n"].raw.must_equal(9007199254740993_i64)
  end

  it "keeps a quoted wide literal a plain string" do
    doc = YAML.parse(%(n: "123456789012345678901234567890"))
    doc["n"].raw.must_equal("123456789012345678901234567890")
  end

  it "carries the sentinel intact through the yaml_value_to_json round trip" do
    doc = YAML.parse("n: 123456789012345678901234567890")
    JSON.parse(doc["n"].to_json).as_s.must_equal(Krikri.bigint_sentinel("123456789012345678901234567890"))
  end
end

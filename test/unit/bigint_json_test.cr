require "../minitest_helper"
require "../../src/krikri/bigint_json"

# The bigint-aware plugin-output parse (Krikri::BigJson, issue #364): an
# integer wider than Int64 in a module's JSON wire result used to raise
# "Invalid Int64" out of plain JSON.parse; the helper stores it as the
# BIGINT_SENTINEL_PREFIX-marked decimal string instead, so every renderer
# taught about the marker prints it back as bare unquoted digits - the
# text Ansible's Python ints produce.
describe "Krikri::BigJson" do
  it "parses a huge positive integer into the marked string" do
    digits = "23800965703753858131193085529022479458634183690853911634056306445954070220687950718656"
    parsed = Krikri::BigJson.parse(%({"m": #{digits}}))
    parsed["m"].as_s.must_equal(Krikri.bigint_sentinel(digits))
  end

  it "parses a huge negative integer with its sign kept" do
    digits = "-170141183460469231731687303715884105728"
    parsed = Krikri::BigJson.parse(%({"m": #{digits}}))
    parsed["m"].as_s.must_equal(Krikri.bigint_sentinel(digits))
  end

  it "keeps the Int64 boundary values as real Int64s" do
    parsed = Krikri::BigJson.parse(%({"max": 9223372036854775807, "min": -9223372036854775808}))
    parsed["max"].as_i64.must_equal(9223372036854775807_i64)
    parsed["min"].as_i64.must_equal(-9223372036854775808_i64)
  end

  it "turns the first integer beyond Int64 into the marked string" do
    parsed = Krikri::BigJson.parse(%({"over": 9223372036854775808}))
    parsed["over"].as_s.must_equal(Krikri.bigint_sentinel("9223372036854775808"))
  end

  it "leaves the digits of a STRING untouched" do
    digits = "23800965703753858131193085529022479458634183690853911634056306445954070220687950718656"
    parsed = Krikri::BigJson.parse(%({"s": "#{digits}", "k": {"#{digits}": [ "#{digits}" ]}}))
    parsed["s"].as_s.must_equal(digits)
    parsed["k"].as_h[digits].as_a[0].as_s.must_equal(digits)
  end

  it "parses floats as floats" do
    parsed = Krikri::BigJson.parse(%({"f": 1.5, "e": 1e300}))
    parsed["f"].as_f.must_equal(1.5)
    parsed["e"].as_f.must_equal(1e300)
  end

  it "parses nested arrays and objects whole" do
    parsed = Krikri::BigJson.parse(%({"a": [1, [2, {"b": null}]], "o": {"x": {"y": true}}, "z": []}))
    parsed["a"].as_a[1].as_a[1].as_h["b"].raw.must_be_nil
    parsed["o"].as_h["x"].as_h["y"].as_bool.must_equal(true)
    parsed["z"].as_a.must_equal([] of JSON::Any)
  end

  it "matches JSON.parse on ordinary documents" do
    text = %({"changed": false, "rc": 0, "msg": "ok", "list": [1, 2.5, "x", null, true]})
    Krikri::BigJson.parse(text).to_json.must_equal(JSON.parse(text).to_json)
  end

  it "rejects trailing garbage like JSON.parse does" do
    assert_raises(JSON::ParseException) { Krikri::BigJson.parse(%({"a": 1} trailing)) }
    assert_raises(JSON::ParseException) { Krikri::BigJson.parse("") }
  end

  it "consumes a fraction-plus-exponent tail as ONE float token" do
    # The exponent digits after a fraction used to be re-scanned by the
    # main loop as a fresh number token, wrapping a long exponent into a
    # sentinel-quoted string and corrupting the document into invalid
    # JSON; now the whole tail is consumed in one go, and the resulting
    # float overflow error is exactly what plain JSON.parse raises.
    assert_raises(JSON::ParseException) do
      Krikri::BigJson.parse(%({"f": 1.5e12345678901234567890}))
    end
    assert_raises(JSON::ParseException) { Krikri::BigJson.parse(%({"f": 1.5e400})) }
    parsed = Krikri::BigJson.parse(%({"f": 1.5e10, "g": 2.5e-7, "h": 1e300}))
    parsed["f"].as_f.must_equal(1.5e10)
    parsed["g"].as_f.must_equal(2.5e-7)
    parsed["h"].as_f.must_equal(1e300)
  end

  it "orders a wide integer against a float exactly" do
    modulus = "23688257652569231524904892537921609541236628215987918620647196265444254471219156591869830489816504690519050309738252706082906790370102917250013129807758266102036883360127166136832204551631104600018667512152866155447082040452828229084282082666887141431193046290573892051314225817230079732316580520281882349855927157561531766920329152776188412700104203560881623485424031595287444870709234449503813475884970204145019343410169951496067118683377577690877581826204994621521701045839752511443311726408982371278248533694344325362281793968655068114590705165735570867322661989881649035151803040759774533128975731350221690748159"
    # Converting these digits to Float64 raises "Invalid Float64"; the
    # comparison must not, and must match Python's exact int/float
    # ordering (live-verified: `m >= 1.5` True, `1.5 >= m` False).
    Krikri::BigJson.bigint_cmp_float(modulus, 1.5).must_equal(1)
    Krikri::BigJson.bigint_cmp_float(modulus, 1e300).must_equal(1)
    Krikri::BigJson.bigint_cmp_float(modulus, -1e300).must_equal(1)
    Krikri::BigJson.bigint_cmp_float("-" + modulus, 1.5).must_equal(-1)
    Krikri::BigJson.bigint_cmp_float("-" + modulus, -1e300).must_equal(-1)
    Krikri::BigJson.bigint_cmp_float("-" + modulus, 0.0).must_equal(-1)
    Krikri::BigJson.bigint_cmp_float(modulus, 0.0).must_equal(1)
    Krikri::BigJson.bigint_cmp_float("0", 0.0).must_equal(0)
    # In-range values compare exactly - no Float64 rounding.
    Krikri::BigJson.bigint_cmp_float("9007199254740993", 9007199254740992.0).must_equal(1)
    Krikri::BigJson.bigint_cmp_float("9007199254740992", 9007199254740992.0).must_equal(0)
    Krikri::BigJson.bigint_cmp_float("18446744073709551615", 1.8446744073709552e19).must_equal(-1)
    # 2^100 is exactly representable as a float; +-1 around it is not.
    Krikri::BigJson.bigint_cmp_float("1267650600228229401496703205377", 2.0**100).must_equal(1)
    Krikri::BigJson.bigint_cmp_float("1267650600228229401496703205376", 2.0**100).must_equal(0)
    Krikri::BigJson.bigint_cmp_float("1267650600228229401496703205375", 2.0**100).must_equal(-1)
    Krikri::BigJson.bigint_cmp_float("1", 1.0).must_equal(0)
    Krikri::BigJson.bigint_cmp_float("2", 1.5).must_equal(1)
    Krikri::BigJson.bigint_cmp_float("1", 1.5).must_equal(-1)
    Krikri::BigJson.bigint_cmp_float("1", Float64::INFINITY).must_equal(-1)
    Krikri::BigJson.bigint_cmp_float("1", -Float64::INFINITY).must_equal(1)
  end

  it "compares marked values exactly and by magnitude" do
    big = Krikri.bigint_sentinel("100000000000000000000000000000000")
    bigger = Krikri.bigint_sentinel("100000000000000000000000000000001")
    negative = Krikri.bigint_sentinel("-100000000000000000000000000000000")
    big_digits = "100000000000000000000000000000000"
    bigger_digits = "100000000000000000000000000000001"
    negative_digits = "-100000000000000000000000000000000"
    Krikri.bigint_digits(big).must_equal(big_digits)
    Krikri.bigint_digits(bigger).must_equal(bigger_digits)
    Krikri.bigint_digits(negative).must_equal(negative_digits)
    Krikri.bigint_cmp(big_digits, big_digits).must_equal(0)
    Krikri.bigint_cmp(bigger_digits, big_digits).must_equal(1)
    Krikri.bigint_cmp(big_digits, bigger_digits).must_equal(-1)
    Krikri.bigint_cmp(negative_digits, big_digits).must_equal(-1)
    Krikri.bigint_cmp(big_digits, "9223372036854775807").must_equal(1)
    Krikri.bigint_digits("plain string").must_be_nil
    Krikri.bigint_digits("#{Krikri::BIGINT_SENTINEL_PREFIX}not digits").must_be_nil
  end
end

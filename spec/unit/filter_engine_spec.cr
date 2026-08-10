require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/filter_engine"

private def s(value : String) : JSON::Any
  JSON::Any.new(value)
end

describe CrystalPlay::VariableSubstitutor::FilterEngine do
  engine = CrystalPlay::VariableSubstitutor::FilterEngine.new

  it "applies default when value is empty" do
    engine.apply(s(""), %(default('fallback'))).as_s.should eq("fallback")
  end

  it "applies default when value is JSON null (undefined)" do
    engine.apply(JSON::Any.new(nil), %(default('fallback'))).as_s.should eq("fallback")
  end

  it "leaves non-empty values untouched by default" do
    engine.apply(s("present"), %(default('fallback'))).as_s.should eq("present")
  end

  it "parses an unquoted numeric default as a number, not a string" do
    engine.apply(JSON::Any.new(nil), "default(0)").as_i.should eq(0)
  end

  it "default(fallback, true) also replaces a real, defined-but-falsy value" do
    # Real bug found benchmarking geerlingguy.php: `pm.max_requests = {{
    # item.pool_pm_max_requests | default(500, true) }}` where the real
    # value is the int 0 (a legitimate, deliberately-set value meaning
    # "unlimited", not a mistake) - defined and non-nil, so `undefined?`
    # alone never caught it, always leaving the real 0 instead of the
    # role's own intended fallback of 500. The 2-arg boolean form must
    # also replace any falsy value (0, false, empty array/hash), not
    # just nil/empty-string.
    engine.apply(JSON::Any.new(0_i64), "default(500, true)").as_i.should eq(500)
    engine.apply(JSON::Any.new(false), "default('yes', true)").as_s.should eq("yes")
  end

  it "default(fallback) without the boolean form leaves a falsy-but-defined value alone" do
    engine.apply(JSON::Any.new(0_i64), "default(500)").as_i.should eq(0)
  end

  it "uppercases with upper" do
    engine.apply(s("hello"), "upper").as_s.should eq("HELLO")
  end

  it "lowercases with lower" do
    engine.apply(s("HELLO"), "lower").as_s.should eq("hello")
  end

  it "capitalizes with capitalize" do
    engine.apply(s("hello world"), "capitalize").as_s.should eq("Hello world")
  end

  it "title-cases with title" do
    engine.apply(s("hello world"), "title").as_s.should eq("Hello World")
  end

  it "trims whitespace with trim" do
    engine.apply(s("  hello  "), "trim").as_s.should eq("hello")
  end

  it "reports length of a string" do
    engine.apply(s("hello"), "length").as_i.should eq(5)
  end

  it "reports length of an array" do
    engine.apply(JSON.parse(%([1, 2, 3])), "length").as_i.should eq(3)
  end

  it "replaces substrings with replace" do
    engine.apply(s("hello world"), %(replace('world', 'there'))).as_s.should eq("hello there")
  end

  it "splits into a real array, not just the first element" do
    result = engine.apply(s("a,b,c"), %(split(','))).as_a.map(&.as_s)
    result.should eq(["a", "b", "c"])
  end

  it "returns the value unchanged for an unknown filter" do
    engine.apply(s("hello"), "mystery").as_s.should eq("hello")
  end

  it "sorts an array" do
    result = engine.apply(JSON.parse(%(["banana", "apple", "cherry"])), "sort").as_a.map(&.as_s)
    result.should eq(["apple", "banana", "cherry"])
  end

  it "sorts numerically when every element parses as a number" do
    result = engine.apply(JSON.parse(%([10, 2, 33])), "sort").as_a.map(&.as_i)
    result.should eq([2, 10, 33])
  end

  it "dedupes with unique" do
    result = engine.apply(JSON.parse(%(["a", "b", "a", "c", "b"])), "unique").as_a.map(&.as_s)
    result.should eq(["a", "b", "c"])
  end

  it "reverses an array" do
    result = engine.apply(JSON.parse(%([1, 2, 3])), "reverse").as_a.map(&.as_i)
    result.should eq([3, 2, 1])
  end

  it "joins an array into a string" do
    engine.apply(JSON.parse(%(["a", "b", "c"])), %(join(','))).as_s.should eq("a,b,c")
  end

  it "extracts an attribute from each hash in an array via map(attribute=...)" do
    value = JSON.parse(%([{"path": "/a", "size": 1}, {"path": "/b", "size": 2}]))
    result = engine.apply(value, %(map(attribute='path'))).as_a.map(&.as_s)
    result.should eq(["/a", "/b"])
  end

  it "chains map(attribute=...) into sort into join - the exact shape find:'s output needs" do
    value = JSON.parse(%([{"path": "/z"}, {"path": "/a"}, {"path": "/m"}]))
    result = engine.apply_chain(value, %(map(attribute='path') | sort | join(',')))
    result.as_s.should eq("/a,/m,/z")
  end

  it "does not split a | that appears inside a quoted filter argument" do
    chain = CrystalPlay::VariableSubstitutor::FilterEngine.split_chain(%(replace('a|b', 'c') | upper))
    chain.should eq([%(replace('a|b', 'c')), "upper"])
  end

  it "converts to int/float/string/bool" do
    engine.apply(s("42"), "int").as_i.should eq(42)
    engine.apply(s("3.5"), "float").as_f.should eq(3.5)
    engine.apply(JSON::Any.new(7_i64), "string").as_s.should eq("7")
    engine.apply(s(""), "bool").as_bool.should eq(false)
    engine.apply(s("yes"), "bool").as_bool.should eq(true)
  end

  it "returns first/last/min/max of an array" do
    value = JSON.parse(%([3, 1, 2]))
    engine.apply(value, "first").as_i.should eq(3)
    engine.apply(value, "last").as_i.should eq(2)
    engine.apply(value, "min").as_i.should eq(1)
    engine.apply(value, "max").as_i.should eq(3)
  end

  it "strips the last path component with dirname, and keeps only it with basename" do
    # Real bug found benchmarking geerlingguy.mysql: entirely
    # unimplemented before, so `path | dirname` fell through to the
    # unknown-filter passthrough (the full path unchanged) - a `file:
    # {path: "{{ mysql_log_error | dirname }}", state: directory}` task
    # then created a directory at the *full* log-error path itself
    # instead of its parent, so mysqld found a directory where it
    # expected to open its error log file and failed to start.
    engine.apply(s("/var/log/mysql/mysql.err"), "dirname").as_s.should eq("/var/log/mysql")
    engine.apply(s("/var/log/mysql/mysql.err"), "basename").as_s.should eq("mysql.err")
  end
end

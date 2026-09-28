require "../minitest_helper"
require "../support/jinja_render_helper"
require "../../src/krikri/jmespath"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/krikri_jinja_filters"

# Regression spec for the `json_query` filter's JMESPath engine
# (src/krikri/jmespath.cr). Found unimplemented via itigoag.packages'
# own `packages_var_lower | json_query(packages_var_query)` task -
# "No filter named 'json_query'" failed the task outright (round 300
# Kata campaign, 0.9.735).

private def j(text : String) : JSON::Any
  JSON.parse(text)
end

describe Krikri::JMESPath do
  describe "field access" do
    it "resolves a top-level identifier" do
      Krikri::JMESPath.evaluate("foo", j(%({"foo": "bar"}))).as_s.must_equal("bar")
    end

    it "resolves a nested path" do
      Krikri::JMESPath.evaluate("a.b.c", j(%({"a": {"b": {"c": 7}}}))).as_i.must_equal(7)
    end

    it "resolves a quoted identifier" do
      Krikri::JMESPath.evaluate(%("weird-key"), j(%({"weird-key": 1}))).as_i.must_equal(1)
    end

    it "yields null for a missing field" do
      Krikri::JMESPath.evaluate("missing", j(%({"foo": 1}))).raw.must_be_nil
    end
  end

  describe "indices, slices and wildcards" do
    private def data
      j(%([0, 1, 2, 3, 4, 5]))
    end

    it "indexes positively and negatively" do
      Krikri::JMESPath.evaluate("[1]", data).as_i.must_equal(1)
      Krikri::JMESPath.evaluate("[-1]", data).as_i.must_equal(5)
      Krikri::JMESPath.evaluate("[10]", data).raw.must_be_nil
    end

    it "slices with start:stop:step" do
      Krikri::JMESPath.evaluate("[1:4]", data).as_a.map(&.as_i).must_equal([1, 2, 3])
      Krikri::JMESPath.evaluate("[::2]", data).as_a.map(&.as_i).must_equal([0, 2, 4])
      Krikri::JMESPath.evaluate("[::-1]", data).as_a.map(&.as_i).must_equal([5, 4, 3, 2, 1, 0])
    end

    it "projects a wildcard over an array" do
      result = Krikri::JMESPath.evaluate("[*].name", j(%([{"name": "a"}, {"name": "b"}, {"other": 1}])))
      result.as_a.map(&.as_s).must_equal(["a", "b"])
    end

    it "projects a hash wildcard over its values" do
      result = Krikri::JMESPath.evaluate("*.port", j(%({"web": {"port": 80}, "db": {"port": 5432}})))
      result.as_a.map(&.as_i).sort!.must_equal([80, 5432])
    end

    it "flattens nested arrays with []" do
      result = Krikri::JMESPath.evaluate("[]", j(%([[1, 2], [3], [], [4]])))
      result.as_a.map(&.as_i).must_equal([1, 2, 3, 4])
    end
  end

  describe "filters and multiselects" do
    it "filters array elements with [?expr]" do
      data = j(%([{"name": "a", "on": true}, {"name": "b", "on": false}, {"name": "c", "on": true}]))
      result = Krikri::JMESPath.evaluate("[?on].name", data)
      result.as_a.map(&.as_s).must_equal(["a", "c"])
    end

    it "supports comparisons inside a filter" do
      data = j(%([{"n": "x", "v": 1}, {"n": "y", "v": 5}]))
      result = Krikri::JMESPath.evaluate("[?v > `3`].n", data)
      result.as_a.map(&.as_s).must_equal(["y"])
    end

    it "builds a multi-select list" do
      result = Krikri::JMESPath.evaluate("[a, b]", j(%({"a": 1, "b": 2})))
      result.as_a.map(&.as_i).must_equal([1, 2])
    end

    it "builds a multi-select hash" do
      result = Krikri::JMESPath.evaluate("{x: a, y: b}", j(%({"a": 1, "b": 2})))
      result.as_h["x"].as_i.must_equal(1)
      result.as_h["y"].as_i.must_equal(2)
    end
  end

  describe "pipes, logic and the current node" do
    it "pipes results into the next expression" do
      result = Krikri::JMESPath.evaluate("items[*].v | [0]", j(%({"items": [{"v": 9}, {"v": 8}]})))
      result.as_i.must_equal(9)
    end

    it "supports && / || / !" do
      data = j(%({"a": true, "b": false}))
      expect(falsey?(Krikri::JMESPath.evaluate("a && b", data).raw)).must_equal(true)
      expect(truthy?(Krikri::JMESPath.evaluate("a || b", data).raw)).must_equal(true)
      expect(falsey?(Krikri::JMESPath.evaluate("!a", data).raw)).must_equal(true)
    end

    it "applies the current node in a function argument" do
      result = Krikri::JMESPath.evaluate("length(@)", j(%([1, 2, 3])))
      result.as_i.must_equal(3)
    end

    it "evaluates backtick literals" do
      Krikri::JMESPath.evaluate("`42`", j(%({"a": 1}))).as_i.must_equal(42)
      Krikri::JMESPath.evaluate("`\"s\"`", j(%({"a": 1}))).as_s.must_equal("s")
    end
  end

  describe "functions" do
    it "length/keys/values/type" do
      data = j(%({"a": 1, "b": 2}))
      Krikri::JMESPath.evaluate("keys(@)", data).as_a.map(&.as_s).sort!.must_equal(["a", "b"])
      Krikri::JMESPath.evaluate("values(@)", data).as_a.map(&.as_i).sort!.must_equal([1, 2])
      Krikri::JMESPath.evaluate("type(@)", data).as_s.must_equal("object")
      Krikri::JMESPath.evaluate("type('x')", data).as_s.must_equal("string")
      Krikri::JMESPath.evaluate("length('hello')", data).as_i.must_equal(5)
    end

    it "sort/sort_by/min/max/min_by/max_by/reverse" do
      data = j(%([3, 1, 2]))
      Krikri::JMESPath.evaluate("sort(@)", data).as_a.map(&.as_i).must_equal([1, 2, 3])
      Krikri::JMESPath.evaluate("reverse(@)", data).as_a.map(&.as_i).must_equal([2, 1, 3])
      Krikri::JMESPath.evaluate("min(@)", data).as_i.must_equal(1)
      Krikri::JMESPath.evaluate("max(@)", data).as_i.must_equal(3)
      items = j(%([{"n": "b", "v": 2}, {"n": "a", "v": 1}]))
      Krikri::JMESPath.evaluate("sort_by(@, &v)[0].n", items).as_s.must_equal("a")
      Krikri::JMESPath.evaluate("min_by(@, &v).n", items).as_s.must_equal("a")
      Krikri::JMESPath.evaluate("max_by(@, &v).n", items).as_s.must_equal("b")
      Krikri::JMESPath.evaluate("map(&n, @)", items).as_a.map(&.as_s).must_equal(["b", "a"])
    end

    it "join/contains/starts_with/ends_with/sum/avg/to_string/to_number/not_null/merge" do
      Krikri::JMESPath.evaluate("join(', ', @)", j(%(["a", "b"]))).as_s.must_equal("a, b")
      expect(truthy?(Krikri::JMESPath.evaluate("contains(@, `2`)", j(%([1, 2, 3]))).raw)).must_equal(true)
      expect(truthy?(Krikri::JMESPath.evaluate("contains(@, 'ell')", j(%("hello"))).raw)).must_equal(true)
      expect(truthy?(Krikri::JMESPath.evaluate("starts_with(@, 'he')", j(%("hello"))).raw)).must_equal(true)
      expect(truthy?(Krikri::JMESPath.evaluate("ends_with(@, 'lo')", j(%("hello"))).raw)).must_equal(true)
      Krikri::JMESPath.evaluate("sum(@)", j(%([1, 2, 3]))).as_i.must_equal(6)
      Krikri::JMESPath.evaluate("avg(@)", j(%([2, 4]))).as_f.must_equal(3.0)
      Krikri::JMESPath.evaluate("to_string(@)", j(%({"a": 1}))).as_s.must_equal(%({"a":1}))
      Krikri::JMESPath.evaluate("to_number(@)", j("12")).as_i.must_equal(12)
      Krikri::JMESPath.evaluate("not_null(a, b)", j(%({"b": 5}))).as_i.must_equal(5)
      merged = Krikri::JMESPath.evaluate("merge(`{\"a\": 1}`, `{\"b\": 2}`)", j(%({})))
      merged.as_h.size.must_equal(2)
    end
  end

  it "raises JMESPath::Error on a syntactically invalid expression" do
    assert_raises(Krikri::JMESPath::Error) do
      Krikri::JMESPath.evaluate("foo..", j(%({"foo": 1})))
    end
  end
end

describe "json_query filter (FilterEngine / Crinja)" do
  private def engine
    Krikri::VariableSubstitutor::FilterEngine.new
  end

  it "is registered in the hand-rolled FilterEngine" do
    data = JSON.parse(%([{"name": "nginx"}, {"name": "vim"}]))
    result = engine.apply(data, %(json_query('[*].name')))
    result.as_a.map(&.as_s).must_equal(["nginx", "vim"])
  end

  it "is registered as a template filter too (the itigoag.packages shape)" do
    rendered = krikri_jinja_render(%({{ packages | json_query(query) }}), {
      "packages" => [{"name" => "htop", "state" => "present"}, {"name" => "curl", "state" => "absent"}],
      "query"    => "[?state == 'present'].name",
    })
    rendered.strip.must_equal(%(['htop']))
  end

  it "fails the template on an invalid expression, like real Ansible" do
    assert_raises_message(Exception, /json_query/) do
      krikri_jinja_render(%({{ packages | json_query('..') }}), {"packages" => [1]})
    end
  end
end

require "../minitest_helper"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/variable_substitutor/expression_evaluator"

private def engine : Krikri::VariableSubstitutor::FilterEngine
  Krikri::VariableSubstitutor::FilterEngine.new
end

private def j(json : String) : JSON::Any
  JSON.parse(json)
end

describe "Krikri::VariableSubstitutor::FilterEngine (lists_mergeby_test.cr)" do
  include RaisesAssertion
  describe "lists_mergeby" do
    include RaisesAssertion
    it "merges two lists of dicts by a shared key, later list winning on collisions" do
      value = j(%([{"name": "a", "port": 1}, {"name": "b", "port": 2}]))
      result = engine.apply(value, %(lists_mergeby([{"name": "a", "host": "x"}], "name")))
      result.as_a.size.must_equal(2)
      # First-seen key order preserved; the colliding item's dicts merged.
      result.as_a[0].as_h["name"].as_s.must_equal("a")
      result.as_a[0].as_h["port"].as_i.must_equal(1)
      result.as_a[0].as_h["host"].as_s.must_equal("x")
      result.as_a[1].as_h["port"].as_i.must_equal(2)
    end

    it "accepts three or more lists (varargs before the merge key)" do
      value = j(%([{"k": "a", "v": 1}]))
      result = engine.apply(value, %(lists_mergeby([{"k": "b", "v": 2}], [{"k": "a", "extra": true}, {"k": "b", "extra": true}], "k")))
      result.as_a.size.must_equal(2)
      result.as_a[0].as_h["extra"].as_bool.must_equal(true)
      result.as_a[1].as_h["extra"].as_bool.must_equal(true)
    end

    it "works with the collection-qualified community.general.lists_mergeby spelling" do
      value = j(%([{"name": "x", "state": 1}]))
      result = engine.apply(value, %(community.general.lists_mergeby([{"name": "x", "state": 2}], "name")))
      result.as_a[0].as_h["state"].as_i.must_equal(2)
    end

    it "works with the deprecated pre-3.x list_mergeby alias" do
      value = j(%([{"name": "x", "n": 1}]))
      result = engine.apply(value, %(list_mergeby([{"name": "x", "m": 2}], "name")))
      result.as_a[0].as_h["m"].as_i.must_equal(2)
    end

    it "replaces nested dicts wholesale with recursive=False (default)" do
      value = j(%([{"name": "a", "opts": {"x": 1, "y": 2}}]))
      result = engine.apply(value, %(lists_mergeby([{"name": "a", "opts": {"z": 3}}], "name")))
      result.as_a[0].as_h["opts"].as_h.size.must_equal(1)
      result.as_a[0].as_h["opts"].as_h["z"]?.try(&.as_i).must_equal(3)
    end

    it "deep-merges nested dicts with recursive=True" do
      value = j(%([{"name": "a", "opts": {"x": 1, "y": 2}}]))
      result = engine.apply(value, %(lists_mergeby([{"name": "a", "opts": {"z": 3}}], "name", recursive=True)))
      result.as_a[0].as_h["opts"].as_h["x"].as_i.must_equal(1)
      result.as_a[0].as_h["opts"].as_h["y"].as_i.must_equal(2)
      result.as_a[0].as_h["opts"].as_h["z"].as_i.must_equal(3)
    end

    it "appends colliding list values with list_merge=append" do
      value = j(%([{"name": "a", "tags": ["x"]}]))
      result = engine.apply(value, %(lists_mergeby([{"name": "a", "tags": ["y"]}], "name", list_merge='append')))
      result.as_a[0].as_h["tags"].as_a.map(&.as_s).must_equal(["x", "y"])
    end

    it "raises when a list item is not a dict" do
      value = j(%([{"name": "a"}, "nope"]))
      assert_raises_message(Exception, "lists_mergeby: list item is not a dict") do
        engine.apply(value, %(lists_mergeby([], "name")))
      end
    end

    it "raises when an item is missing the merge key" do
      value = j(%([{"name": "a"}, {"other": "b"}]))
      assert_raises_message(Exception, "merge key 'name' not found") do
        engine.apply(value, %(lists_mergeby([], "name")))
      end
    end

    it "resolves the merge key from a variable reference, not just a literal" do
      vars = Hash(String, JSON::Any).new
      vars["mkey"] = JSON::Any.new("name")
      scoped = Krikri::VariableSubstitutor::FilterEngine.new(vars)
      value = j(%([{"name": "a", "v": 1}]))
      result = scoped.apply(value, %(lists_mergeby([{"name": "a", "w": 2}], mkey)))
      result.as_a[0].as_h["w"].as_i.must_equal(2)
    end
  end
end

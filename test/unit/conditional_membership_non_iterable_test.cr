require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# Python's `in` calls the container's __contains__, so a container that
# cannot be iterated at all (None, int, float, bool) raises TypeError
# instead of answering: real ansible fails the clause "Error rendering
# expression: argument of type 'NoneType' is not iterable" (live-verified
# vs 2.21.6 for null/int/float/bool variables and a `none` literal).
# Answering false instead inverted `not in` and ran tasks real dies on -
# issue #1911, srikalyan.docker's `docker_compose_current_version`, a
# `regex_search` over an empty stdout, is null on a host without a
# docker-compose binary and its `... not in docker_compose_current_version`
# gate then let the file task run.
describe "Krikri::ConditionalEvaluator (conditional_membership_non_iterable_test.cr)" do
  private def vars
    {
      "docker_compose_current_version" => JSON::Any.new(nil),
      "docker_compose_version"         => JSON::Any.new("v2.11.1"),
      "my_int"                         => JSON::Any.new(5_i64),
      "my_float"                       => JSON::Any.new(1.5),
      "my_bool"                        => JSON::Any.new(true),
    }
  end

  it "raises RenderExpressionError for `not in` a null variable (issue #1911)" do
    assert_raises_message(Krikri::RenderExpressionError,
      "argument of type 'NoneType' is not iterable") do
      Krikri::ConditionalEvaluator.evaluate(
        "docker_compose_current_version is defined and (docker_compose_version | regex_replace('v', '')) not in docker_compose_current_version",
        vars, strict: true, raise_undefined: true)
    end
  end

  it "raises for `in` a null variable too" do
    assert_raises_message(Krikri::RenderExpressionError,
      "argument of type 'NoneType' is not iterable") do
      Krikri::ConditionalEvaluator.evaluate("'x' in docker_compose_current_version", vars,
        strict: true, raise_undefined: true)
    end
  end

  it "names a yaml-sourced int container the way ansible's datatags do" do
    assert_raises_message(Krikri::RenderExpressionError,
      "argument of type '_AnsibleTaggedInt' is not iterable") do
      Krikri::ConditionalEvaluator.evaluate("'x' in my_int", vars, strict: true, raise_undefined: true)
    end
  end

  it "names a yaml-sourced float container the way ansible's datatags do" do
    assert_raises_message(Krikri::RenderExpressionError,
      "argument of type '_AnsibleTaggedFloat' is not iterable") do
      Krikri::ConditionalEvaluator.evaluate("'x' in my_float", vars, strict: true, raise_undefined: true)
    end
  end

  it "names a bool container 'bool'" do
    assert_raises_message(Krikri::RenderExpressionError,
      "argument of type 'bool' is not iterable") do
      Krikri::ConditionalEvaluator.evaluate("'x' in my_bool", vars, strict: true, raise_undefined: true)
    end
  end

  it "names the `none` literal 'NoneType'" do
    assert_raises_message(Krikri::RenderExpressionError,
      "argument of type 'NoneType' is not iterable") do
      Krikri::ConditionalEvaluator.evaluate("'x' in none", vars, strict: true, raise_undefined: true)
    end
  end

  # The lenient ternary/inventory-filter fallbacks are not task-level
  # clauses and keep their long-standing false answer, the same split
  # raise_consumed_undefined! makes for undefined references.
  it "keeps answering false for a lenient (raise_undefined: false) caller" do
    Krikri::ConditionalEvaluator.evaluate("'x' in docker_compose_current_version", vars).must_equal(false)
  end

  # Iterable containers must keep answering normally next to the raises.
  it "still evaluates membership against a string and a list" do
    v = vars
    v["my_str"] = JSON::Any.new("v2.11.1")
    v["my_list"] = JSON.parse(%(["a", "b"]))
    Krikri::ConditionalEvaluator.evaluate("'11' in my_str", v, strict: true, raise_undefined: true).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("'a' in my_list", v, strict: true, raise_undefined: true).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("'z' not in my_list", v, strict: true, raise_undefined: true).must_equal(true)
  end
end

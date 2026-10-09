require "../minitest_helper"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_filters"

# Two divergences from round 5250000's opsta.graylog set_fact
# (`graylog_search_config_paths: "{{ graylog_search_config_paths +
# [graylog_search_config_path] }}'"` looped over group_names), both verified
# against ansible-core 2.19.11 locally:
#
# 1. A variable whose own value is MULTI-SPAN template text with literal
#    text around the spans (`{{ playbook_dir }}/groups/{{ item }}/graylog`)
#    was fed to the expression evaluator as if it were an expression when
#    read through a plain `+` operand - its literal `/` characters were
#    parsed as division operators, failing the whole set_fact with
#    `unsupported operand type(s) for /: 'dict' and 'NoneType'`.
# 2. The same accumulation inside a mixed-text set_fact value stored the
#    span's list with JSON-compact quoting (`["..."]'`) where real renders
#    the Python repr (`['...']'`) - native typing only applies to a
#    whole-single-span value, so a mixed value must render as text.
describe "multi-span var values in plus operands (multi_span_plus_operand_test.cr)" do
  # evaluate_output is the user-facing form a mixed-text task param renders
  # through (output:true) - its container results carry the Python repr.
  private def evaluator_for(vars)
    Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars)
  end

  it "re-renders a multi-span var value as a template, not an expression" do
    v = Hash(String, JSON::Any).new
    v["base"] = JSON::Any.new("/opt/base")
    v["suffix"] = JSON::Any.new("{{ base }}/groups/{{ item }}/graylog")
    v["item"] = JSON::Any.new("all")
    evaluator = evaluator_for(v)
    evaluator.evaluate_output("[] + [suffix]").must_equal("['/opt/base/groups/all/graylog']")
  end

  it "keeps whole-single-span operand values on the expression path" do
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new("{{ 6 }}")
    evaluator = evaluator_for(v)
    evaluator.evaluate_output("[1] + [n * 2]").must_equal("[1, 12]")
  end

  it "keeps a mixed-text var value verbatim around its rendered spans" do
    v = Hash(String, JSON::Any).new
    v["p"] = JSON::Any.new("/a")
    v["mixed"] = JSON::Any.new("x{{ p }}y")
    evaluator = evaluator_for(v)
    evaluator.evaluate_output("['z'] + [mixed]").must_equal("['z', 'x/ay']")
  end
end

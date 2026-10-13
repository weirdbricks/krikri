require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# ansible-core 2.19.11: a variable whose stored text uses block tags and
# renders to nothing is None (`v.rstrip(";")` fails with "object of type
# 'NoneType' has no attribute 'rstrip'"), while `{{ "" }}` and a literal ''
# stay "". inofix.yapkg's for-loop-built `yapkg_list` is the real case;
# krikri kept "" and let the task run.
describe "Krikri::VarSubstitutor (var_block_template_empty_is_none_test.cr)" do
  it "turns an empty block-tag render into None" do
    sub = Krikri::VarSubstitutor.new(vars: {
      "lst" => JSON::Any.new([] of JSON::Any),
      "sl"  => JSON::Any.new("{% for p in lst %}x;{% endfor %}"),
    }, host_name: "h")
    sub.substitute("{{ sl is none }}").must_equal("True")
  end

  it "keeps an empty {{ }} render and a literal empty string as a string" do
    sub = Krikri::VarSubstitutor.new(vars: {
      "a" => JSON::Any.new("{{ '' }}"),
      "b" => JSON::Any.new(""),
    }, host_name: "h")
    sub.substitute("{{ a is none }}").must_equal("False")
    sub.substitute("{{ b is none }}").must_equal("False")
  end
end

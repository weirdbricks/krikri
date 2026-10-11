require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_filters"

# `query('flattened', '{{ snmpd_debian_packages }}')` - the "double-templated"
# lookup-term idiom (rhaamo.snmpd round 5460199): ansible-core templates every
# string lookup term (listify_lookup_plugin_terms, with a deprecation warning)
# before the plugin runs, so the flattened lookup deep-flattens the REAL list.
# Three separate legs had to hold for the round's
# `apt: name: "{{ query('flattened', '{{ snmpd_debian_packages }}') }}"`
# to install snmp/snmpd/snmp-mibs-downloader instead of a package literally
# named "undefined":
# - the hand-rolled evaluator's double-templated re-render must not re-quote
#   a CONTAINER-shaped render (its interior quotes broke re-evaluation into
#   the "undefined" sentinel - the round's actual `install '['undefined']'`
#   apt command);
# - the krikri-jinja engine's flattened branch must honor query()'s
#   list-forcing (previously the comma-joined string came back and the
#   register wrapper re-wrapped it into `["a,b"]`);
# - the engine must template the term at all (previously the literal
#   `{{ l }}` text reached the plugin);
# - the param finalization's whole-single-span detection must not treat the
#   nested quoted braces as extra spans (that demoted the param to
#   output:true repr text instead of the native-typed container).
describe "Krikri::VariableSubstitutor::ExpressionEvaluator flattened double-templated terms (flattened_lookup_double_templated_test.cr)" do
  it "re-renders a double-templated list term into the real flattened list" do
    v = Hash(String, JSON::Any).new
    v["snmpd_debian_packages"] = JSON.parse(%(["snmp", "snmpd", "snmp-mibs-downloader"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("query('flattened', '{{ snmpd_debian_packages }}')")).as_a.map(&.as_s)
      .must_equal(["snmp", "snmpd", "snmp-mibs-downloader"])
  end

  it "comma-joins a double-templated list term in scalar lookup() form" do
    v = Hash(String, JSON::Any).new
    v["snmpd_debian_packages"] = JSON.parse(%(["snmp", "snmpd", "snmp-mibs-downloader"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("lookup('flattened', '{{ snmpd_debian_packages }}')")
      .must_equal("snmp,snmpd,snmp-mibs-downloader")
  end

  it "flattens a double-templated term mixed with a plain literal term" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["a", "b"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("query('flattened', '{{ l }}', 'c')")).as_a.map(&.as_s)
      .must_equal(["a", "b", "c"])
  end

  it "keeps a quoted JSON-literal term a single string item (never re-parsed as a list)" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("query('flattened', '[\"a\",\"b\"]')")).as_a.map(&.as_s)
      .must_equal(["[\"a\",\"b\"]"])
  end

  it "keeps a double-templated SCALAR term a scalar through the re-render" do
    v = Hash(String, JSON::Any).new
    v["path"] = JSON::Any.new("/etc/snmp")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("query('flattened', '{{ path }}')")).as_a.map(&.as_s)
      .must_equal(["/etc/snmp"])
  end
end

describe "Krikri::VariableSubstitutor::JinjaRenderer engine flattened lookups (flattened_lookup_double_templated_test.cr)" do
  it "keeps query('flattened', bare_list) a real flattened list (query list-forcing)" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["a", "b"]))
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)

    renderer.evaluate_value!("query('flattened', l)").not_nil!.as_a.map(&.as_s).must_equal(["a", "b"])
  end

  it "re-templates a double-templated term into the real flattened list" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["a", "b"]))
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)

    renderer.evaluate_value!("query('flattened', '{{ l }}')").not_nil!.as_a.map(&.as_s).must_equal(["a", "b"])
  end

  it "keeps scalar lookup('flattened', bare_list) comma-joined" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["a", "b"]))
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)

    renderer.render(%({{ lookup('flattened', l) }})).must_equal("a,b")
  end
end

describe "Krikri::VarSubstitutor.single_top_level_span? (flattened_lookup_double_templated_test.cr)" do
  it "counts a double-templated literal's nested braces as quoted text, not extra spans" do
    Krikri::VarSubstitutor.single_top_level_span?("{{ query('flattened', '{{ l }}') }}").must_equal(true)
    Krikri::VarSubstitutor.single_top_level_span?(%({{ query('flattened', "{{ l }}") }})).must_equal(true)
  end

  it "still rejects genuinely multi-span and mixed text" do
    Krikri::VarSubstitutor.single_top_level_span?("{{ a }}{{ b }}").must_equal(false)
    Krikri::VarSubstitutor.single_top_level_span?("pre {{ a }}").must_equal(false)
    Krikri::VarSubstitutor.single_top_level_span?("{{ a }} post {{ b }}").must_equal(false)
  end

  it "still accepts a plain single span" do
    Krikri::VarSubstitutor.single_top_level_span?("{{ l }}").must_equal(true)
    Krikri::VarSubstitutor.single_top_level_span?("{{query('flattened', l)}}").must_equal(true)
  end
end

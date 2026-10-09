require "../minitest_helper"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_filters"

# Ansible's vars lookup runs the found value through the templar before
# returning it, so a lazily-templated role var (`vars/main.yml: "_quiet:
# '{{ ext_quiet | default(...) }}'"`) renders AT the lookup instead of
# surfacing as raw `{{ }}` text. The direct `{{ _quiet }}` reference path
# already re-rendered; only the by-name fetch skipped it - which made
# sscheib.openwrt_extroot's assert loop fail its
# `lookup('ansible.builtin.vars', '_ext_quiet_assert') is boolean` check
# against the literal template text (round 5250000). Verified against
# ansible-core 2.19.11 locally before being encoded here.
describe "vars lookup renders the found value (vars_lookup_rerender_test.cr)" do
  private def evaluator
    v = Hash(String, JSON::Any).new
    v["ext_quiet"] = JSON::Any.new(true)
    v["_quiet"] = JSON::Any.new("{{ ext_quiet | bool }}")
    v["_def_quiet"] = JSON::Any.new("false")
    Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
  end

  it "renders a templated role var returned by lookup('vars', ...)" do
    evaluator.evaluate("lookup('vars', '_quiet')").must_equal("True")
  end

  it "renders through the FQN spelling lookup('ansible.builtin.vars', ...)" do
    evaluator.evaluate("lookup('ansible.builtin.vars', '_quiet')").must_equal("True")
  end

  it "passes an already-plain value through unchanged" do
    evaluator.evaluate("lookup('vars', '_def_quiet')").must_equal("false")
  end

  it "keeps the explicit-default escape hatch for a missing key" do
    evaluator.evaluate("lookup('vars', 'no_such_var', default='fallback')").must_equal("fallback")
  end
end

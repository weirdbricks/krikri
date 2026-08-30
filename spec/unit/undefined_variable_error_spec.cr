require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# Real bug found benchmarking robertdebock.bios_update on Rocky 9.6 (round
# 161): real Ansible's Jinja2 templating for module args is
# strict-undefined by default - `debug: msg: "Error: {{ some_var }}"`
# where some_var is genuinely never set anywhere raises "Finalization of
# task args ... failed: 'some_var' is undefined" and fails the task. This
# engine otherwise renders a missing lookup as the literal string
# "undefined" and continues (a deliberate, pervasive leniency used
# throughout when:/changed_when:/failed_when: evaluation and most of
# VariableSubstitutor - NOT changed). `VarSubstitutor#substitute`'s new
# `strict:` parameter (used only by #substitute_task_params, the one
# place that assembles a task's final module-arg hash) narrowly re-adds
# real Ansible's strictness for the single most common, unambiguous
# shape of this bug: a BARE variable reference (`foo`, `foo.bar`,
# `foo['bar'][0]` - no filters/operators/function calls) that resolves to
# nothing.
describe Krikri::VarSubstitutor do
  describe "#substitute with strict: true" do
    it "raises UndefinedVariableError for a bare undefined top-level variable" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /'totally_undefined_var' is undefined/) do
        sub.substitute("Value: {{ totally_undefined_var }}", strict: true)
      end
    end

    it "raises UndefinedVariableError for a bare undefined dotted reference" do
      vars = {"bios_update_url" => JSON::Any.new("http://example.com")}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /'bios_update_download_bios_update_bootable_cd' is undefined/) do
        sub.substitute("Error: {{ bios_update_download_bios_update_bootable_cd }}", strict: true)
      end
    end

    it "does not raise when the variable is genuinely defined" do
      vars = {"name" => JSON::Any.new("alpha")}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("Value: {{ name }}", strict: true).should eq("Value: alpha")
    end

    it "does not raise when a dict key exists but is missing an attribute (evaluator-shape fallback, not a bare reference)" do
      # Deliberately narrow scope: only a *bare* {{ var }} span is
      # checked - a value going through any filter/operator/function
      # still uses the lenient path regardless of strict:, since this
      # hand-rolled evaluator's own known syntax gaps already fall back
      # to the same "undefined" sentinel for reasons unrelated to the
      # variable genuinely being undefined.
      vars = {"existing" => JSON.parse(%({"foo": "bar"}))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("Value: {{ existing.missing | default('fallback') }}", strict: true).should eq("Value: fallback")
    end

    it "does not raise under plain (non-strict) substitute - matches when:/vars-file/etc. semantics unchanged" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
      sub.substitute("Value: {{ totally_undefined_var }}").should eq("Value: undefined")
    end
  end
end

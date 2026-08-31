require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# Real bug found benchmarking bimdata.ferm's own get_vars.j2
# (`{% set ns = namespace(items=[]) %}`): the strict `{% %}` block-tag
# undefined scan (scan_block_tag_refs) treats a `{% set var = EXPR %}`
# tag's RHS the same way an `{% if %}` condition is scanned - matching
# every bare identifier in EXPR against `@vars`. A Jinja2 global
# function CALL like `namespace(...)` matched "namespace" as a bare
# identifier, wasn't in `@vars` (it's a function, not a variable), and
# raised "'namespace' is undefined" - even though Crinja itself
# resolves `namespace()` (and any other builtin global function, or a
# user-defined `{% macro %}`) just fine once actually rendered; this
# strict pre-check crashed before Crinja ever got the chance.
describe "strict block-tag scan: a called identifier is never a bare variable ref" do
  it "does not flag namespace(...) as an undefined variable inside {% set %}" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

    sub.substitute("{% set ns = namespace(x=1) %}{{ ns.x }}", strict: true).should eq("1")
  end

  it "still flags a genuinely undefined BARE variable (not a call) inside {% set %}" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

    expect_raises(Krikri::UndefinedVariableError, /'nosuch' is undefined/) do
      sub.substitute("{% set x = nosuch %}{{ x }}", strict: true)
    end
  end
end

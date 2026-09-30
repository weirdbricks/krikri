require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# Real ansible-core 2.19.11 renders `{{ esc }}` where esc's own value is
# `{{ '{{' }} literal {{ '}}' }}` to the literal TEXT "{{ literal }}" and
# never re-scans that output; krikri's span re-pass templated the finished
# brace text a second time ("{{ literal }}" -> "literal") or crashed on it.
describe "Krikri::VarSubstitutor (var_substitutor_brace_literal_rerender_test.cr)" do
  it "renders a var holding brace-literal template text exactly one pass" do
    sub = Krikri::VarSubstitutor.new(vars: {"esc" => JSON::Any.new("{{ '{{' }} literal {{ '}}' }}")}, host_name: "h")
    sub.substitute("{{ esc }}").must_equal("{{ literal }}")
    sub.substitute("A{{ esc }}B").must_equal("A{{ literal }}B")
  end

  it "still re-templates a raw passthrough var chain to full depth" do
    sub = Krikri::VarSubstitutor.new(vars: {"a" => JSON::Any.new("{{ b }}"), "b" => JSON::Any.new("{{ c }}"), "c" => JSON::Any.new("0755")}, host_name: "h")
    sub.substitute("{{ a }}").must_equal("0755")
  end

  it "still re-templates a passthrough list of template strings" do
    sub = Krikri::VarSubstitutor.new(vars: {"deps" => JSON::Any.new([JSON::Any.new("{{ x }}"), JSON::Any.new("pkg")]), "x" => JSON::Any.new("htop")}, host_name: "h")
    sub.substitute("{{ deps }}").must_include("htop")
  end
end

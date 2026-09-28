require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# P1.2 (FINDINGS_CHECKLIST.md) - the resolution-path parity guard.
#
# Every shape below reads a variable whose OWN stored value is an unrendered
# block-tag template. The original P1.1 bug (round 200, andrewrothstein.
# traefik) showed up on exactly one of these shapes; this table pins ALL of
# them so a future resolution path (or a regression in the two root causes
# P1.1 actually had) fails loudly here instead of one benchmark round at a
# time:
#
#   1. `scan_block_tag_refs` checked a dotted/bracketed chain as a flat
#      @vars key, so ANY `{% if %}` using ordinary attribute access on a
#      defined dict was "undefined" under strict - and
#      `JinjaRenderer.convert_var`'s `unresolvable_template?` probe turned
#      that into a real Crinja::Undefined for the whole variable.
#   2. `rerender_string_value` only re-rendered values containing `{{`, so
#      a pure `{% %}`-block value reached Crinja's context raw - invisible
#      to a bare `{{ v }}` (the outer re-pass loop saved that shape) but
#      fatal as a FILTER-CHAIN HEAD (`upper` mangled the tag keywords so no
#      later pass could parse them) and as a `default()` argument.
#
# Expected value is always "A" (`{% if flag %}A{% else %}B{% endif %}` with
# flag true); verified against ansible-core 2.19.4 semantics.

private BLOCK = "{% if flag %}A{% else %}B{% endif %}"

private def guard_vars : Hash(String, JSON::Any)
  h = Hash(String, JSON::Any).new
  h["flag"] = JSON::Any.new("true")
  h["v"] = JSON::Any.new(BLOCK)
  h["obj"] = JSON.parse(%({"attr": "#{BLOCK}"}))
  h["arr"] = JSON.parse(%(["#{BLOCK}"]))
  h
end

describe "block-tag-valued variable resolves through every lookup path" do
  include RaisesAssertion

  # crystal spec's `it` can be generated from a loop (it expands to a class,
  # not a def); minitest's expands to `def`, which Crystal cannot declare
  # inside a block, and whose name must be a plain string literal. Spelled out.
  def substitute_shape(tpl : String, expected : String, strict : Bool)
    sub = Krikri::VarSubstitutor.new(vars: guard_vars, host_name: "h")
    sub.substitute(tpl, strict: strict).must_equal(expected)
  end

  it "bare reference" do
    substitute_shape("{{ v }}", "A", strict: false)
  end

  it "dotted base" do
    substitute_shape("{{ obj.attr }}", "A", strict: false)
  end

  it "indexed element" do
    substitute_shape("{{ arr[0] }}", "A", strict: false)
  end

  it "filter-chain head" do
    substitute_shape("{{ v | upper }}", "A", strict: false)
  end

  it "default() argument" do
    substitute_shape("{{ missing | default(v) }}", "A", strict: false)
  end

  it "ternary branch" do
    substitute_shape("{{ v if flag else 'x' }}", "A", strict: false)
  end

  it "inside a larger literal+template string" do
    substitute_shape("pre-{{ v }}-post", "pre-A-post", strict: false)
  end

  it "include_tasks filename shape (strict)" do
    substitute_shape("v{{ v }}.yml", "vA.yml", strict: true)
  end

  it "strict path still raises for a block-tag condition rooted at a MISSING var" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")
    assert_raises_message(Krikri::UndefinedVariableError, /'nosuch' is undefined/) do
      sub.substitute("{% if nosuch.attr == 'x' %}y{% endif %}", strict: true)
    end
  end
end

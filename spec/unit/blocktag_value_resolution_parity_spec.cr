require "../spec_helper"
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
#      `CrinjaRenderer.convert_var`'s `unresolvable_template?` probe turned
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
  shapes = {
    "bare reference"                          => {"{{ v }}", "A"},
    "dotted base"                             => {"{{ obj.attr }}", "A"},
    "indexed element"                         => {"{{ arr[0] }}", "A"},
    "filter-chain head"                       => {"{{ v | upper }}", "A"},
    "default() argument"                      => {"{{ missing | default(v) }}", "A"},
    "ternary branch"                          => {"{{ v if flag else 'x' }}", "A"},
    "inside a larger literal+template string" => {"pre-{{ v }}-post", "pre-A-post"},
    "include_tasks filename shape (strict)"   => {"v{{ v }}.yml", "vA.yml"},
  }

  shapes.each do |label, (tpl, expected)|
    it label do
      strict = label.includes?("strict")
      sub = Krikri::VarSubstitutor.new(vars: guard_vars, host_name: "h")
      sub.substitute(tpl, strict: strict).should eq(expected)
    end
  end

  it "strict path still raises for a block-tag condition rooted at a MISSING var" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")
    expect_raises(Krikri::UndefinedVariableError, /'nosuch' is undefined/) do
      sub.substitute("{% if nosuch.attr == 'x' %}y{% endif %}", strict: true)
    end
  end
end

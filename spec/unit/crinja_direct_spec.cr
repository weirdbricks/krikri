require "../spec_helper"
# Regression canary against raw Crinja (Crinja.new / env.from_string(...).
# render) - deliberately bypassing this codebase's own CrinjaRenderer
# wrapper. The point (per CRINJA.md's "Also worth doing opportunistically"
# note): after a fork rebase or `shards update`, these specs tell you at a
# glance whether a maintained registration / behavior became (a) redundant
# (fixed upstream - then the redundant crystal-ansible fix can be deleted)
# or (b) newly broken (a regression to chase). They are NOT testing
# CrinjaRenderer's own re-templating/var-context machinery - crinja_
# renderer_spec.cr covers that.
#
# Requires the real Ansible-specific registrations (jinja_filters.cr), as
# every real template-rendering binary pulls them in via
# template_action_plugin.cr.
require "../../src/crystal_play/jinja_filters"

private def crinja_render(tpl : String, vars = nil) : String
  env = Crinja.new
  env.from_string(tpl).render(vars)
end

describe "raw Crinja (rebase canary)" do
  # Bool finalization is Python-parity "True"/"False" (was lowercase
  # true/false in the fork before the intentional fix).
  it "finalizes bare booleans capitalized, Python-style" do
    crinja_render("{{ true }}|{{ false }}").should eq("True|False")
  end

  it "keeps `and`/`or` as value selectors, returning the winning operand" do
    crinja_render("{{ '' or 'fallback' }}").should eq("fallback")
    crinja_render("{{ 'x' or 'y' }}").should eq("x")
    crinja_render("{{ 1 and 2 }}").should eq("2")
  end

  it "supports the in / not in operators (was entirely absent)" do
    crinja_render("{{ 'a' in ['a', 'b'] }}").should eq("True")
    crinja_render("{{ 'a' not in ['a', 'b'] }}").should eq("False")
    crinja_render("{{ 'enabled' not in 'disabled' }}").should eq("True")
  end

  it "renders native inline ternary" do
    crinja_render("{{ 'a' if true else 'b' }}").should eq("a")
    crinja_render("{{ 'a' if false else 'b' }}").should eq("b")
    crinja_render("{{ ('a' if false else 'b' if false else 'c') }}").should eq("c")
  end

  # dict() single positional-iterable form (fork crystal-play-0.9.4).
  it "builds a dict from a positional iterable of pairs" do
    crinja_render("{{ dict([['a', 1], ['b', 2]]) }}").should eq("{'a': 1, 'b': 2}")
    crinja_render("{{ dict({'x': 'y'}) }}").should eq("{'x': 'y'}")
  end

  # to_datetime (jinja_filters.cr) + fork Time subtraction -> TimeDelta.days
  # (fork crystal-play-0.9.5). CF CRINJA.md step-5 next-step #3.
  it "subtracts two to_datetime values and reads .days" do
    crinja_render(
      "{{ (a | to_datetime('%b %d, %Y') - b | to_datetime('%b %d, %Y')).days }}",
      {"a" => "Jan 02, 2024", "b" => "Jan 01, 2024"}
    ).should eq("1")
  end

  # Ansible-specific filters/tests that live in jinja_filters.cr and must
  # stay registered - a future fork addition would make these redundant
  # (then can be deleted), a regression would fail here.
  it "registers the regex_search filter with backreference arg" do
    crinja_render("{{ 'aa12bb' | regex_search('(\\d+)', '\\1') }}").should eq("12")
  end

  it "registers combine (shallow merge, later wins)" do
    crinja_render("{{ {'a': 1, 'b': 2} | combine({'b': 3, 'c': 4}) }}").should eq("{'a': 1, 'b': 3, 'c': 4}")
  end

  # dict2items / items2dict - real Ansible's own filters (NOT standard
  # Jinja2; Python/Jinja2 reject them as "No filter named ..."), mirrored
  # here in jinja_filters.cr so a `.j2` template's `{% for %}` block-tag
  # chain can use them. The hand-rolled FilterEngine has the same pair
  # for the plain `{{ }}` filter chain (spec/unit/filter_engine_spec.cr) -
  # this is the Crinja-side dual registration the project's CRINJA.md
  # warns is the bug class that historically lived independently in both
  # evaluators.
  it "registers dict2items (default key_name='key', value_name='value')" do
    crinja_render("{{ {'a': 1, 'b': 2} | dict2items | length }}").should eq("2")
    crinja_render("{{ {'a': 1} | dict2items | first | type_debug }}").should eq("dict")
    crinja_render("{{ {'a': 1} | dict2items | first }}").should eq("{'key': 'a', 'value': 1}")
  end

  it "registers dict2items with custom key_name and value_name kwargs" do
    crinja_render("{{ {'x': 'foo'} | dict2items(key_name='name', value_name='data') | first }}").should eq("{'name': 'x', 'data': 'foo'}")
  end

  it "registers items2dict (inverse of dict2items, later-wins on key collision)" do
    crinja_render("{{ [{'key': 'a', 'value': 1}, {'key': 'b', 'value': 2}] | items2dict }}").should eq("{'a': 1, 'b': 2}")
    crinja_render("{{ [{'key': 'a', 'value': 1}, {'key': 'a', 'value': 2}] | items2dict }}").should eq("{'a': 2}")
  end

  it "registers items2dict with custom key_name and value_name kwargs" do
    crinja_render("{{ [{'name': 'x', 'data': 'foo'}] | items2dict(key_name='name', value_name='data') }}").should eq("{'x': 'foo'}")
  end

  it "registers intersect and flatten" do
    crinja_render("{{ [1, 2, 3] | intersect([2, 3, 4]) | sort | join(',') }}").should eq("2,3")
    crinja_render("{{ [1, [2, 3], 4] | flatten | join(',') }}").should eq("1,2,3,4")
  end

  it "registers type_debug / basename / dirname / to_nice_yaml" do
    crinja_render("{{ 'x' | type_debug }}").should eq("str")
    crinja_render("{{ '/a/b/c.txt' | basename }}").should eq("c.txt")
    crinja_render("{{ '/a/b/c.txt' | dirname }}").should eq("/a/b")
  end

  it "registers the boolean / integer / float type tests" do
    crinja_render("{{ true is boolean }}|{{ 'true' is boolean }}").should eq("True|False")
    crinja_render("{{ 5 is integer }}|{{ 5.5 is integer }}").should eq("True|False")
    crinja_render("{{ 5.5 is float }}|{{ 5 is float }}").should eq("True|False")
  end

  it "registers the register-result tests (failed/changed/succeeded...)" do
    result = {"failed" => false, "changed" => true}
    crinja_render("{{ r is failed }}|{{ r is changed }}|{{ r is succeeded }}", {"r" => result}).should eq("False|True|True")
  end

  # Python string-method support on the fork's String values.
  it "supports .split() and .startswith()/.endswith() string methods" do
    crinja_render("{{ s.split() | join(',') }}", {"s" => "a b"}).should eq("a,b")
    crinja_render("{{ m.startswith('/home') }}", {"m" => "/home/user"}).should eq("True")
    crinja_render("{{ m.endswith('.j2') }}", {"m" => "config.j2"}).should eq("True")
  end

  it "keeps first/list/join lenient on Undefined input" do
    crinja_render("{{ missing | first }}").should eq("")
    crinja_render("{{ missing | join(',') }}").should eq("")
    crinja_render("{% set x = missing | list %}{{ x }}").should eq("[]")
  end
end

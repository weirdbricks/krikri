require "../spec_helper"
require "../../src/krikri/variable_substitutor/crinja_renderer"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/jinja_filters"

# Regression specs for the general lazy-dict-templating gap
# (KNOWN_MISSING.md's last open entry, closed 0.9.741).
#
# Real Ansible's templar keeps a variable computed from a `{{ }}`
# expression a genuine dict/list through the whole vars pipeline
# (_AnsibleLazyTemplateDict). krikri's substitution is string-based, but
# recovers real types via the render-then-parse-back machinery added
# piecemeal over rounds 303-305 - which left two residual divergence
# classes this file pins, both verified shape-for-shape against real
# ansible-core 2.19 (output-diffed, /tmp battery playbooks):
#
# 1. The vendored crinja fork's iteration default for a BARE dict
#    (fixed in fork release crystal-play-0.9.25: keys-only, Python
#    semantics, everywhere - `list`, `join`, `first`/`last`, `min`/
#    `max`, `unique`, `map`, `select`, `reverse`, `urlencode`).
# 2. `combine(recursive=True)` / `list_merge=` silently ignoring both
#    kwargs (fixed in both evaluators: FilterEngine#combine_hash and
#    jinja_filters.cr's Crinja-side combine).
module LazyDictSpecHelpers
  def self.prep(v : Hash(String, JSON::Any), name : String, raw : String)
    v[name] = Krikri::VariableSubstitutor::CrinjaRenderer.rerender_nested_templates(
      JSON::Any.new(raw), Krikri::VarSubstitutor.new(vars: v)
    )
  end

  def self.render(v : Hash(String, JSON::Any), tpl : String)
    Krikri::VariableSubstitutor::CrinjaRenderer.new(v).render(tpl).strip
  end
end

describe "lazy dict-templating: a computed dict var behaves like a real dict" do
  v = Hash(String, JSON::Any).new
  v["d1"] = JSON.parse(%({"b": 2, "a": 1, "c": 3}))
  v["d2"] = JSON.parse(%({"b": 20, "c": 30}))
  LazyDictSpecHelpers.prep(v, "computed", "{{ d1 | combine(d2) }}")

  # Real ansible-core 2.19: "single: [a][b][c]"
  it "iterates KEYS for a single-variable for over a computed dict" do
    LazyDictSpecHelpers.render(v, "{% for k in computed %}[{{ k }}]{% endfor %}")
      .should eq("[b][a][c]")
  end

  # Real ansible-core 2.19: "pairs: (a=1)(b=20)(c=30)"
  it "iterates (key, value) pairs via .items()" do
    LazyDictSpecHelpers.render(v, "{% for k, val in computed.items() %}({{ k }}={{ val }}) {% endfor %}")
      .should eq("(b=20) (a=1) (c=30)")
  end

  # Real ansible-core 2.19: "sort: [a][b][c]"
  it "sorts a computed dict to its keys" do
    LazyDictSpecHelpers.render(v, "{% for k in computed | sort %}[{{ k }}]{% endfor %}")
      .should eq("[a][b][c]")
  end

  # Real ansible-core 2.19: "items-sort: (a=1)(b=20)(c=30)"
  it "sorts an .items() result to pairs" do
    LazyDictSpecHelpers.render(v, "{% for pair in computed.items() | sort %}({{ pair[0] }}={{ pair[1] }}) {% endfor %}")
      .should eq("(a=1) (b=20) (c=30)")
  end

  # Real ansible-core 2.19: "chain: (a=1)(b=20)(c=30)(d=40)" - a set_fact
  # computed from ANOTHER computed dict stays a real dict through the
  # whole chain.
  it "keeps a chained computed dict a real dict" do
    LazyDictSpecHelpers.prep(v, "chain", "{{ computed | combine({'d': 40}) }}")
    LazyDictSpecHelpers.render(v, "{% for k, val in chain.items() | sort %}({{ k }}={{ val }}) {% endfor %}")
      .should eq("(a=1) (b=20) (c=30) (d=40)")
  end

  # Real ansible-core 2.19, every shape output-diffed:
  # list ['b','a','c'] / join b,a,c / first b, last c / min a, max c /
  # unique ['b','a','c'] / map ['B','A','C'] / select ['b','a'] /
  # reverse ['c','a','b'] - crystal-play-0.9.25's keys-only flip.
  it "exposes Python keys-only semantics to every dict consumer" do
    LazyDictSpecHelpers.render(v, "{{ computed | list }}").should eq("['b', 'a', 'c']")
    LazyDictSpecHelpers.render(v, "{{ d1 | join(',') }}").should eq("b,a,c")
    LazyDictSpecHelpers.render(v, "{{ d1 | first }}").should eq("b")
    LazyDictSpecHelpers.render(v, "{{ d1 | last }}").should eq("c")
    LazyDictSpecHelpers.render(v, "{{ d1 | min }}").should eq("a")
    LazyDictSpecHelpers.render(v, "{{ d1 | max }}").should eq("c")
    LazyDictSpecHelpers.render(v, "{{ d1 | unique | list }}").should eq("['b', 'a', 'c']")
    LazyDictSpecHelpers.render(v, "{{ d1 | map('upper') | list }}").should eq("['B', 'A', 'C']")
    LazyDictSpecHelpers.render(v, "{{ d1 | select('match', '[ab]') | list }}").should eq("['b', 'a']")
    LazyDictSpecHelpers.render(v, "{{ d1 | reverse | list }}").should eq("['c', 'a', 'b']")
  end

  # Real ansible-core 2.19 hard-FAILS the bare two-variable form over a
  # dict ("not enough values to unpack"); krikri deliberately keeps it
  # working (jtyr.nsswitch/jtyr.motd shipped and were live-verified on
  # it) - now built by the for tag itself, not by Value#each's default.
  it "keeps the lenient two-variable pairs form working" do
    LazyDictSpecHelpers.render(v, "{% for k, val in d1 %}({{ k }}={{ val }}) {% endfor %}")
      .should eq("(b=2) (a=1) (c=3)")
  end

  # Real ansible-core 2.19: "dictsort: [['a', 0], ...]" - dictsort keeps
  # returning (key, value) pairs after the keys-flip, AND renders as
  # bracketed nested lists (ansible-core's native-types finalization
  # converts tuples to lists at every output position - the paren-repr
  # form this spec originally encoded as expected was itself the bug).
  it "keeps dictsort returning (key, value) pairs" do
    LazyDictSpecHelpers.render(v, "{{ d1 | dictsort }}")
      .should eq("[['a', 1], ['b', 2], ['c', 3]]")
  end

  # Same tuple→list conversion at the JSON boundary: a dictsort result
  # interpolated mid-text (not as a whole-{{ }} span) and a computed
  # .items() pair list must both render bracketed, matching real Ansible.
  it "renders tuple results as bracketed lists in every output position" do
    LazyDictSpecHelpers.render(v, "value is {{ d1 | dictsort }} ok")
      .should eq("value is [['a', 1], ['b', 2], ['c', 3]] ok")
    LazyDictSpecHelpers.prep(v, "pairs", "{{ d1.items() | list }}")
    LazyDictSpecHelpers.render(v, "{{ pairs }}")
      .should eq("[['b', 2], ['a', 1], ['c', 3]]")
  end

  # Real ansible-core 2.19: "{{ d1 | dictsort | string }}" renders
  # "[('a', 1), ('b', 2), ('c', 3)]" - | string is Python str() BEFORE
  # the native-types tuple->list conversion, the one output position
  # where the paren repr survives. Verified shape-for-shape.
  it "keeps the paren repr for | string applied inline to tuple results" do
    LazyDictSpecHelpers.render(v, "{{ d1 | dictsort | string }}")
      .should eq("[('a', 1), ('b', 2), ('c', 3)]")
    LazyDictSpecHelpers.render(v, "{{ d1 | dictsort | first | string }}")
      .should eq("('a', 1)")
  end
end

describe "combine recursive=True deep-merges and list_merge= governs list collisions" do
  engine = Krikri::VariableSubstitutor::FilterEngine.new
  dict = JSON.parse(%({"o": {"a": {"x": 1}, "l": [1, 2]}, "top": 1}))
  override = JSON.parse(%({"o": {"a": {"y": 2}, "l": [3]}}))

  it "deep-merges nested dicts instead of replacing them" do
    result = engine.apply(dict, %(combine(#{override.to_json}, recursive=True)))
    result["o"]["a"].as_h.should eq({
      "x" => JSON.parse(%(1)), "y" => JSON.parse(%(2)),
    })
    result["o"]["l"].as_a.map(&.as_i).should eq([3])
  end

  it "replaces nested dicts wholesale without recursive=True (unchanged default)" do
    result = engine.apply(dict, %(combine(#{override.to_json})))
    result["o"]["a"].as_h.should eq({"y" => JSON.parse(%(2))})
  end

  it "supports every list_merge mode, matching real ansible-core 2.19" do
    %w(replace keep append prepend append_rp prepend_rp).each do |mode|
      result = engine.apply(dict, %(combine(#{override.to_json}, recursive=True, list_merge='#{mode}')))
      expected = case mode
                 when "replace"   then [3]
                 when "append_rp" then [1, 2, 3]
                 when "keep"      then [1, 2]
                 when "append"    then [1, 2, 3]
                 else                  [3, 1, 2] # prepend, prepend_rp
                 end
      result["o"]["l"].as_a.map(&.as_i).should eq(expected)
    end
  end

  it "accepts unquoted recursive=True (the form real roles write)" do
    result = engine.apply(dict, %(combine(#{override.to_json}, recursive=True)))
    result["o"]["a"].as_h.size.should eq(2)
  end

  it "the Crinja-side combine filter deep-merges the same way" do
    v = Hash(String, JSON::Any).new
    v["d1"] = JSON.parse(%({"o": {"a": 1}, "l": [1]}))
    v["d2"] = JSON.parse(%({"o": {"b": 2}, "l": [2]}))
    LazyDictSpecHelpers.prep(v, "merged", "{{ d1 | combine(d2, recursive=True) }}")
    LazyDictSpecHelpers.render(v, "{% for k, val in merged.o.items() | sort %}{{ k }}{{ val }}{% endfor %}")
      .should eq("a1b2")
  end
end

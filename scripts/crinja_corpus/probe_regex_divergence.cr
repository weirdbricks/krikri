# Phase-3 Crinja consolidation slice #3 (regex_search + regex_findall)
# divergence probe. Runs the same battery against BOTH implementations of
# each name:
#   OLD = FilterEngine's hand-rolled JSON::Any dispatch (the `case
#         filter_name` branches, also serving map()'s inner per-item path)
#   NEW = the native Crinja.filter(:regex_search)/(:regex_findall)
#         registrations, invoked through the same Arguments mechanics the
#         Crinja-first chain path uses.
# Arbitration oracle for every divergence: real ansible-core (2.19.11)
# via `ansible localhost -m debug -a msg=...` (see the slice report).
# Run from the repo root:
#   crystal run scripts/crinja_corpus/probe_regex_divergence.cr
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

def old_path(value : JSON::Any, filter_expr : String) : String
  engine = Krikri::VariableSubstitutor::FilterEngine.new
  engine.apply(value, filter_expr).to_json
rescue e
  "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
end

def crinja_call(value : JSON::Any, name : String, args : Array(Crinja::Value), kwargs : Crinja::Variables) : String
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters[name]
  arguments = Crinja::Arguments.new(
    env,
    varargs: args,
    kwargs: kwargs,
    target: Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value),
  )
  arguments.defaults = callable.defaults if callable.responds_to?(:defaults)
  Krikri::VariableSubstitutor::CrinjaRenderer.crinja_value_to_json_any(
    callable.call(arguments).as(Crinja::Value)
  ).to_json
rescue e
  "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
end

NO_KWARGS = Crinja::Variables.new

# Each case: [label, input JSON, hand-rolled filter expression, Crinja
# filter name, Crinja varargs, Crinja kwargs]. The hand-rolled expression
# and the varargs+kwargs encode the same call.
battery = [
  # --- regex_search ---
  {"search: basic match", %q("hello world"), %q(regex_search('world')), "regex_search", [Crinja::Value.new("world")], NO_KWARGS},
  {"search: group, no ref", %q("hello world"), %q(regex_search('w(or)ld')), "regex_search", [Crinja::Value.new("w(or)ld")], NO_KWARGS},
  {"search: no match -> null", %q("hello world"), %q(regex_search('xyzzy')), "regex_search", [Crinja::Value.new("xyzzy")], NO_KWARGS},
  {"search: backref \\1", %q("aa12bb"), %q(regex_search('(\d+)', '\1')), "regex_search", [Crinja::Value.new("(\\d+)"), Crinja::Value.new("\\1")], NO_KWARGS},
  {"search: backref \\2 of two groups", %q("ab"), %q(regex_search('(a)(b)', '\2')), "regex_search", [Crinja::Value.new("(a)(b)"), Crinja::Value.new("\\2")], NO_KWARGS},
  {"search: '\\1\\2' single arg (real parses group 1 only)", %q("ab"), %q(regex_search('(a)(b)', '\1\2')), "regex_search", [Crinja::Value.new("(a)(b)"), Crinja::Value.new("\\1\\2")], NO_KWARGS},
  {"search: non-participating group \\2", %q("a"), %q(regex_search('(a)|(b)', '\2')), "regex_search", [Crinja::Value.new("(a)|(b)"), Crinja::Value.new("\\2")], NO_KWARGS},
  {"search: named group \\g<foo>", %q("a"), %q(regex_search('(?<foo>a)', '\g<foo>')), "regex_search", [Crinja::Value.new("(?<foo>a)"), Crinja::Value.new("\\g<foo>")], NO_KWARGS},
  {"search: nonexistent group \\5", %q("aa12bb"), %q(regex_search('(\d+)', '\5')), "regex_search", [Crinja::Value.new("(\\d+)"), Crinja::Value.new("\\5")], NO_KWARGS},
  {"search: nonexistent named group", %q("aa12bb"), %q(regex_search('(\d+)', '\g<bar>')), "regex_search", [Crinja::Value.new("(\\d+)"), Crinja::Value.new("\\g<bar>")], NO_KWARGS},
  {"search: junk group_ref", %q("aa12bb"), %q(regex_search('(\d+)', 'xyz')), "regex_search", [Crinja::Value.new("(\\d+)"), Crinja::Value.new("xyz")], NO_KWARGS},
  {"search: empty group_ref -> whole match", %q("hello world"), %q(regex_search('w(or)ld', '')), "regex_search", [Crinja::Value.new("w(or)ld"), Crinja::Value.new("")], NO_KWARGS},
  {"search: ignorecase kwarg", %q("HELLO"), %q(regex_search('hello', ignorecase=True)), "regex_search", [Crinja::Value.new("hello")], Crinja::Variables{"ignorecase" => Crinja::Value.new(true)}},
  {"search: multiline kwarg", %q("x\nend: 42"), %q(regex_search('^end: (\d+)', '\1', multiline=True)), "regex_search", [Crinja::Value.new("^end: (\\d+)"), Crinja::Value.new("\\1")], Crinja::Variables{"multiline" => Crinja::Value.new(true)}},
  {"search: empty input, empty-match pattern", %q(""), %q(regex_search('x*')), "regex_search", [Crinja::Value.new("x*")], NO_KWARGS},
  {"search: unicode", %q("héllo wörld"), %q(regex_search('w(ö)rld')), "regex_search", [Crinja::Value.new("w(ö)rld")], NO_KWARGS},
  {"search: anchored 64-hex (container facts shape)", %q("abc123"), %q(regex_search('^[0-9a-fX]{64}$')), "regex_search", [Crinja::Value.new("^[0-9a-fX]{64}$")], NO_KWARGS},
  {"search: invalid regex", %q("hello"), %q[regex_search('(')], "regex_search", [Crinja::Value.new("(")], NO_KWARGS},
  # --- regex_findall ---
  {"findall: no groups", %q("a1b2"), %q(regex_findall('[0-9]')), "regex_findall", [Crinja::Value.new("[0-9]")], NO_KWARGS},
  {"findall: ONE group -> flat scalars", %q("Ready for use: >JDK 26<"), %q(regex_findall('Ready for use:.*>JDK ([\d]+)<')), "regex_findall", [Crinja::Value.new("Ready for use:.*>JDK ([\\d]+)<")], NO_KWARGS},
  {"findall: two groups -> nested lists", %q("a1b2c3"), %q(regex_findall('([a-z])(\d)')), "regex_findall", [Crinja::Value.new("([a-z])(\\d)")], NO_KWARGS},
  {"findall: named group counts as one group", %q("v1.2"), %q(regex_findall('(?<ver>\d\.\d)')), "regex_findall", [Crinja::Value.new("(?<ver>\\d\\.\\d)")], NO_KWARGS},
  {"findall: no match -> empty list", %q("hello"), %q(regex_findall('[0-9]')), "regex_findall", [Crinja::Value.new("[0-9]")], NO_KWARGS},
  {"findall: positional multiline/ignorecase", %q("A1\nB2"), %q(regex_findall('^([a-z])\d', True, True)), "regex_findall", [Crinja::Value.new("^([a-z])\\d"), Crinja::Value.new(true), Crinja::Value.new(true)], NO_KWARGS},
  {"findall: ignorecase kwarg (named)", %q("A1B2"), %q(regex_findall('[a-z][0-9]', ignorecase=True)), "regex_findall", [Crinja::Value.new("[a-z][0-9]")], Crinja::Variables{"ignorecase" => Crinja::Value.new(true)}},
  {"findall: multiline kwarg (named)", %q("A1\nb2"), %q(regex_findall('^b(\d)', multiline=True)), "regex_findall", [Crinja::Value.new("^b(\\d)")], Crinja::Variables{"multiline" => Crinja::Value.new(true)}},
  {"findall: empty input", %q(""), %q(regex_findall('[0-9]')), "regex_findall", [Crinja::Value.new("[0-9]")], NO_KWARGS},
  {"findall: non-participating group renders empty", %q("a b"), %q(regex_findall('(a)|(b)')), "regex_findall", [Crinja::Value.new("(a)|(b)")], NO_KWARGS},
  {"findall: unicode", %q("héllo wörld"), %q(regex_findall('ö')), "regex_findall", [Crinja::Value.new("ö")], NO_KWARGS},
  {"findall: invalid regex", %q("hello"), %q[regex_findall('(')], "regex_findall", [Crinja::Value.new("(")], NO_KWARGS},
  {"findall: prometheus checksum line shape", %q("abc123  file1.tar.gz"), %q(regex_findall('^([a-fA-F0-9]+)\s+(.+)$')), "regex_findall", [Crinja::Value.new("^([a-fA-F0-9]+)\\s+(.+)$")], NO_KWARGS},
]

diverged = 0
battery.each do |(label, input_json, filter_expr, name, varargs, kwargs)|
  input = JSON.parse(input_json)
  o = old_path(input, filter_expr)
  n = crinja_call(input, name, varargs, kwargs)
  mark = o == n ? "match  " : "DIVERGE"
  diverged += 1 unless o == n
  puts "  #{mark} #{label}"
  puts "         input: #{input_json}"
  puts "         OLD: #{o}"
  puts "         NEW: #{n}" if o != n
end
puts "  (#{diverged} diverged of #{battery.size})"

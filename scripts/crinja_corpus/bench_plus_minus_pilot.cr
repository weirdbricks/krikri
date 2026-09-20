# Phase-2 Crinja consolidation pilot (arithmetic `+`/`-` constructs)
# performance measurement, companion to the Phase-1 per-filter benches.
# Measures the ExpressionEvaluator dispatch cost for the two constructs
# migrated to Crinja-first delegation in their real role shapes - string
# building (the dominant `+` shape), numeric `+`/`-`, list
# concatenation, the `+` path where Crinja now succeeds where the old
# hand-rolled path string-concatenated (int + float), and the `-`
# fallback path (non-numeric operands, where Crinja raises) - plus
# items2dict's hand-rolled dispatch as an in-tree reference.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_plus_minus_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check). Running this same script once on the pre-change
# commit and once on the post-change tree gives the true before/after
# numbers.

require "../../src/krikri/variable_substitutor"
# The native Crinja.filter registrations run at require time into
# `Crinja::Filter::Library.defaults`, before the shared environment is
# lazily built - benching without this require would measure an
# environment that never saw the registrations (the real binary always
# loads jinja_filters.cr up front via krikri.cr).
require "../../src/krikri/jinja_filters"

N = 100_000

vars = Hash(String, JSON::Any).new
vars["host"] = JSON::Any.new("web1")
vars["port"] = JSON::Any.new(8080_i64)
vars["ratio"] = JSON::Any.new(2.5)
vars["ver"] = JSON::Any.new("2.27.0")
vars["emptylist"] = JSON.parse(%([]))
vars["null_var"] = JSON::Any.new(nil)

items = JSON.parse(({"sysctl_values" => "0644", "mount_mode" => "1777"}.map do |k, v|
  {"key" => k, "value" => v}
end).to_json)

engine = Krikri::VariableSubstitutor::FilterEngine.new

def bench(label : String, n : Int32, &)
  n.times { yield } # warmup (JIT-free in Crystal, but warms caches/allocators)
  start = Time.monotonic
  n.times { yield }
  elapsed = Time.monotonic - start
  per_call_ns = (elapsed.total_nanoseconds / n).round(0)
  puts "#{label.ljust(52)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns.to_i}ns"
end

puts "plus/minus Crinja-first delegation bench (N=#{N})"

bench("'https://...' + ver + '/sums.txt' (string build)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%('https://example.com/v' + ver + '/sums.txt'))
end

bench("host + '.example.com' (string + string)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%(host + '.example.com'))
end

bench("port + 10 (numeric add)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%(port + 10))
end

bench("emptylist + ['x'] (list concat)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%(emptylist + ['x']))
end

bench("port + ratio (int + float; new numeric path)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%(port + ratio))
end

bench("port - 10 (numeric subtract)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%(port - 10))
end

bench("port - null_var (Crinja raises -> fallback)", N) do
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(%(port - null_var))
end

bench("items2dict (hand-rolled, reference filter)", N) do
  engine.apply(items, "items2dict")
end

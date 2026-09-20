# Phase-1 Crinja consolidation, filter #3 (json_query) performance
# measurement, companion to bench_dict2items_pilot.cr (filter #1) and
# bench_combine_pilot.cr (filter #2). Measures the FilterEngine dispatch
# cost for the migrated name in its real role shapes - the itigoag.packages
# list-projection (`[*].name`) and the filter-by-dict-value projection
# (`[?state == 'present'].name`) - against items2dict's hand-rolled
# dispatch as an in-tree reference, and - by running this same script once
# on the pre-change commit and once on the post-change tree - the true
# before/after number for json_query itself.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_json_query_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"
# The native Crinja.filter registrations (json_query among them) run at
# require time into `Crinja::Filter::Library.defaults`, before the shared
# environment is lazily built - benching without this require would
# measure an environment that never saw the registrations (the real
# binary always loads jinja_filters.cr up front via krikri.cr).
require "../../src/krikri/jinja_filters"

N = 100_000

# A realistic role-sized payload - a list of package dicts like the
# registered `package_facts` output itigoag.packages queries.
packages = JSON.parse([
  {"name" => "nginx", "state" => "present", "version" => "1.18.0"},
  {"name" => "vim", "state" => "absent", "version" => "8.2"},
  {"name" => "htop", "state" => "present", "version" => "3.0.5"},
  {"name" => "curl", "state" => "present", "version" => "7.68.0"},
].to_json)

engine = Krikri::VariableSubstitutor::FilterEngine.new

def bench(label : String, n : Int32, &)
  n.times { yield } # warmup (JIT-free in Crystal, but warms caches/allocators)
  start = Time.monotonic
  n.times { yield }
  elapsed = Time.monotonic - start
  per_call_ns = (elapsed.total_nanoseconds / n).round(0)
  puts "#{label.ljust(48)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns.to_i}ns"
end

puts "json_query consolidation bench (N=#{N})"

bench("json_query('[*].name') (list projection)", N) do
  engine.apply(packages, %(json_query('[*].name')))
end

bench("json_query('[?state == \\'present\\'].name')", N) do
  engine.apply(packages, %q(json_query('[?state == 'present'].name')))
end

bench("items2dict (hand-rolled, reference filter)", N) do
  engine.apply(packages, "items2dict")
end

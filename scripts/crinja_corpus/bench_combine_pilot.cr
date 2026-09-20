# Phase-1 Crinja consolidation, filter #2 (combine) performance measurement,
# companion to bench_dict2items_pilot.cr (filter #1). Measures the FilterEngine
# dispatch cost for the migrated name in its real role shapes - a plain
# shallow merge, the recursive=True deep-merge, and the list_merge='append_rp'
# variant - against (a) items2dict's hand-rolled dispatch as an in-tree
# reference and (b) - by running this same script once on the pre-change
# commit and once on the post-change tree - the true before/after number for
# combine itself.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_combine_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"
# The native Crinja.filter registrations (combine among them) run at
# require time into `Crinja::Filter::Library.defaults`, before the shared
# environment is lazily built - benching without this require would
# measure an environment that never saw the registrations (the real
# binary always loads jinja_filters.cr up front via krikri.cr).
require "../../src/krikri/jinja_filters"

N = 100_000

# A realistic role-sized merge - dev-sec os_hardening layers per-OS sysctl
# overrides on top of defaults through chains like
# `sysctl_config | combine(sysctl_custom_config | default({}))`.
base = JSON.parse({
  "a"     => {"x" => 1},
  "l"     => [1, 2],
  "top"   => 1,
  "owner" => "root",
  "port"  => "22",
}.to_json)
override = JSON.parse({"a" => {"y" => 2}, "l" => [3]}.to_json)

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
  puts "#{label.ljust(48)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns.to_i}ns"
end

puts "combine consolidation bench (N=#{N})"

bench("combine 1 positional", N) do
  engine.apply(base, "combine(#{override.to_json})")
end

bench("combine recursive=True", N) do
  engine.apply(base, %(combine(#{override.to_json}, recursive=True)))
end

bench("combine recursive=True list_merge=append_rp", N) do
  engine.apply(base, %(combine(#{override.to_json}, recursive=True, list_merge='append_rp')))
end

bench("items2dict (hand-rolled, reference filter)", N) do
  engine.apply(items, "items2dict")
end

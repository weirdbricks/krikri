# Phase-1 Crinja consolidation cleanup (lists_mergeby) performance
# measurement, companion to bench_combine_pilot.cr (filter #2). Measures the
# FilterEngine dispatch cost for the migrated name in its real role shape -
# claranet.postgresql's vars assembly (`lists | lists_mergeby(lists2, 'key')`)
# - in a plain two-list merge, a three-list varargs merge, the recursive=True
# deep-merge, and the list_merge='append' variant - against (a) items2dict's
# hand-rolled dispatch as an in-tree reference and (b) - by running this same
# script once on the pre-change commit and once on the post-change tree - the
# true before/after number for lists_mergeby itself.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_lists_mergeby_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"
# The native Crinja.filter registrations (lists_mergeby among them) run at
# require time into `Crinja::Filter::Library.defaults`, before the shared
# environment is lazily built - benching without this require would
# measure an environment that never saw the registrations (the real
# binary always loads jinja_filters.cr up front via krikri.cr).
require "../../src/krikri/jinja_filters"

N = 100_000

# A realistic role-sized pair - claranet.postgresql merges lists of
# per-source dict entries (autotune/global/extra settings) keyed by name.
list1 = JSON.parse([
  {"name" => "wal_level", "value" => "replica"},
  {"name" => "max_connections", "value" => 200},
  {"name" => "shared_buffers", "value" => "1GB"},
  {"name" => "work_mem", "value" => "16MB"},
  {"name" => "autovacuum", "value" => true},
].to_json)
list2 = JSON.parse([
  {"name" => "max_connections", "value" => 300},
  {"name" => "shared_buffers", "value" => "2GB"},
  {"name" => "effective_cache_size", "value" => "4GB"},
  {"name" => "maintenance_work_mem", "value" => "512MB"},
].to_json)
list3 = JSON.parse([
  {"name" => "work_mem", "value" => "32MB", "comment" => "tuned"},
].to_json)

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

puts "lists_mergeby consolidation bench (N=#{N})"

bench("lists_mergeby 2 lists", N) do
  engine.apply(list1, "lists_mergeby(#{list2.to_json}, 'name')")
end

bench("lists_mergeby 3 lists", N) do
  engine.apply(list1, "lists_mergeby(#{list2.to_json}, #{list3.to_json}, 'name')")
end

bench("lists_mergeby 2 lists recursive=True", N) do
  engine.apply(list1, %(lists_mergeby(#{list2.to_json}, 'name', recursive=True)))
end

bench("lists_mergeby 2 lists list_merge=append", N) do
  engine.apply(list1, %(lists_mergeby(#{list2.to_json}, 'name', list_merge='append')))
end

bench("items2dict (hand-rolled, reference filter)", N) do
  engine.apply(items, "items2dict")
end

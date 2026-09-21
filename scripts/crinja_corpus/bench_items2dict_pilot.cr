# Phase-3 Crinja consolidation slice #1 (items2dict) performance
# measurement, companion to bench_dict2items_pilot.cr. Measures the
# FilterEngine dispatch cost for items2dict itself - the filter this
# slice migrates from a hand-rolled JSON::Any body onto the native
# Crinja.filter registration via #delegate_to_crinja_filter. Run this
# same script once on the pre-change commit and once on the post-change
# tree for the true before/after number (the dict2items pilot method).
#
# Per-item economics note (the survey's per-item-cost lesson): items2dict
# is a list-of-dicts -> dict reducer, not a per-item transformer - it is
# called once per expression, never inside a map() body - so the
# per-call cost is the whole story and the bridge's JSON::Any <->
# Crinja::Value roundtrip is paid once, not per element.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_items2dict_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

N = 100_000

# A realistic role-sized item list - the shape
# `vars_result.results | items2dict(key_name='item', value_name='...')`
# walks (register-result post-processing, testing/test-include-vars-register.yml).
items = JSON.parse(([
  {"item" => "max_connections", "ansible_facts" => {"val" => "100"}},
  {"item" => "shared_buffers", "ansible_facts" => {"val" => "128MB"}},
  {"item" => "work_mem", "ansible_facts" => {"val" => "4MB"}},
  {"item" => "maintenance_work_mem", "ansible_facts" => {"val" => "64MB"}},
  {"item" => "effective_cache_size", "ansible_facts" => {"val" => "2GB"}},
  {"item" => "wal_buffers", "ansible_facts" => {"val" => "-1"}},
  {"item" => "min_wal_size", "ansible_facts" => {"val" => "80MB"}},
  {"item" => "max_wal_size", "ansible_facts" => {"val" => "1GB"}},
]).to_json)

engine = Krikri::VariableSubstitutor::FilterEngine.new

def bench(label : String, n : Int32, &)
  n.times { yield } # warmup (JIT-free in Crystal, but warms caches/allocators)
  start = Time.monotonic
  n.times { yield }
  elapsed = Time.monotonic - start
  per_call_ns = (elapsed.total_nanoseconds / n).round(0)
  puts "#{label.ljust(44)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns.to_i}ns"
end

puts "items2dict consolidation pilot (N=#{N})"

bench("items2dict (current dispatch)", N) do
  engine.apply(items, "items2dict")
end

bench("items2dict with kwargs (current)", N) do
  engine.apply(items, %(items2dict(key_name='item', value_name='ansible_facts')))
end

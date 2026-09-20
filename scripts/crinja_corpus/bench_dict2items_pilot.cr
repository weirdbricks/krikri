# Phase-1 Crinja consolidation pilot (dict2items) performance measurement,
# companion to bench_evaluators.cr (the dual-evaluator convergence perf
# gate). Measures the FilterEngine dispatch cost for the pilot filter's
# name against (a) a similar filter still implemented hand-rolled in this
# dispatch (items2dict, dict2items' own inverse, same kwarg shape) and
# (b) - by running this same script once on the pre-change commit and once
# on the post-change tree - the true before/after number for dict2items
# itself.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_dict2items_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"
# The native Crinja.filter registrations (dict2items among them) run at
# require time into `Crinja::Filter::Library.defaults`, before the shared
# environment is lazily built - benching without this require would
# measure an environment that never saw the registrations (the real
# binary always loads jinja_filters.cr up front via krikri.cr).
require "../../src/krikri/jinja_filters"

N = 100_000

# A realistic role-sized dict - dev-sec os_hardening walks configs of
# roughly this shape/size through `loop: "{{ os_vars | dict2items }}"`.
dict = JSON.parse({
  "sysctl_values" => "0644",
  "mount_mode"    => "1777",
  "owner"         => "root",
  "group"         => "root",
  "enabled"       => "true",
  "port"          => "22",
  "protocol"      => "tcp",
  "service"       => "sshd",
}.to_json)

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
  puts "#{label.ljust(44)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns.to_i}ns"
end

puts "dict2items consolidation pilot (N=#{N})"

bench("dict2items (delegated -> Crinja)", N) do
  engine.apply(dict, "dict2items")
end

bench("dict2items with kwargs (delegated)", N) do
  engine.apply(dict, %(dict2items(key_name='name', value_name='data')))
end

bench("items2dict (hand-rolled, similar filter)", N) do
  engine.apply(items, "items2dict")
end

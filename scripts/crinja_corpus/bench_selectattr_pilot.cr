# Phase-1 Crinja consolidation, filter #4 (selectattr) performance
# measurement, companion to bench_dict2items_pilot.cr / bench_combine_pilot.cr
# / bench_json_query_pilot.cr. Filter #3's report specifically asked for a
# PER-ITEM profile here (4 / 50 / 500 entries) rather than a flat per-call
# one: a selectattr's cost could compound over list size if delegation
# converts per item, whereas filters #1-2's overhead was a flat per-call
# tax. Compares the current hand-rolled dispatch against a PROTOTYPE of the
# delegated path (the exact same JSON::Any -> Crinja::Value bridge mechanics
# #delegate_to_crinja_filter uses, invoking the fork's native
# Crinja.filter(:selectattr) registration) without changing any production
# code - behavior parity is judged separately in CRINJA_PILOT_REPORT.md.
#
# Run from the repo root:
#   crystal run --release scripts/crinja_corpus/bench_selectattr_pilot.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"
# The native Crinja.filter registrations (selectattr among them) run at
# require time into `Crinja::Filter::Library.defaults`, before the shared
# environment is lazily built - benching without this require would
# measure an environment that never saw the registrations (the real
# binary always loads jinja_filters.cr up front via krikri.cr).
require "../../src/krikri/jinja_filters"

def delegated_selectattr(value : JSON::Any, attr : String, test : String, compare : JSON::Any) : JSON::Any
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters["selectattr"]
  arguments = Crinja::Arguments.new(
    env,
    varargs: [
      Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON::Any.new(attr)),
      Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON::Any.new(test)),
      Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(compare),
    ] of Crinja::Value,
    kwargs: Crinja::Variables.new,
    target: Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value),
  )
  arguments.defaults = callable.defaults if callable.responds_to?(:defaults)
  Krikri::VariableSubstitutor::CrinjaRenderer.crinja_value_to_json_any(callable.call(arguments).as(Crinja::Value))
end

# Realistic hostvar-shaped entries (ansible_facts.mounts-like), every entry
# carrying enough fields to make per-item attribute lookup non-trivial.
def make_entries(n : Int32) : JSON::Any
  entries = (0...n).map do |i|
    {
      "mount"    => "/srv/app#{i}",
      "device"   => "/dev/vd#{('a'.ord + i % 26).chr}#{i}",
      "fstype"   => i % 3 == 0 ? "ext4" : "xfs",
      "state"    => i % 2 == 0 ? "present" : "absent",
      "enabled"  => JSON::Any.new(i % 3 != 1),
      "size"     => JSON::Any.new((i + 1) * 1024_i64),
      "options"  => ["defaults", "nofail"],
      "comments" => "entry #{i} of #{n}",
    }.to_json
  end
  JSON.parse(entries.to_json)
end

def bench(label : String, n : Int32, &)
  n.times { yield } # warmup
  start = Time.monotonic
  n.times { yield }
  elapsed = Time.monotonic - start
  per_call_ns = (elapsed.total_nanoseconds / n).round(0)
  puts "#{label.ljust(58)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns.to_i}ns"
end

N = 20_000

puts "selectattr consolidation bench (N=#{N} per measurement)"

{4, 50, 500}.each do |size|
  entries = make_entries(size)
  engine = Krikri::VariableSubstitutor::FilterEngine.new
  compare = JSON::Any.new("present")

  puts "--- list of #{size} entries ---"
  bench("selectattr('state','equalto','present') OLD  x#{size}", N) do
    engine.apply(entries, %(selectattr('state', 'equalto', 'present')))
  end
  bench("selectattr('state','equalto','present') NEW  x#{size}", N) do
    delegated_selectattr(entries, "state", "equalto", compare)
  end
  bench("rejectattr('enabled') (no test) OLD          x#{size}", N) do
    engine.apply(entries, %(rejectattr('enabled')))
  end
  bench("selectattr('mount') (no test) OLD            x#{size}", N) do
    engine.apply(entries, %(selectattr('mount')))
  end
end

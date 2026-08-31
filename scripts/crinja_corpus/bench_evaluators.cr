# Performance gate for the dual-evaluator convergence work: substitute
# runs 2-4x per task per host, and Crinja re-parses on every from_string -
# its template_cache only covers loader-based templates, not string ones.
#
# Measures three things per representative expression shape:
#   1. the current hand-rolled ExpressionEvaluator#evaluate
#   2. raw Crinja, re-parsing via env.from_string(...).render every call
#      (today's actual CrinjaRenderer behavior for a plain {{ }} escalation)
#   3. raw Crinja with a source-keyed Template cache (parse once, render
#      many) - the fix that makes Crinja fast enough for the hot path
#
# Run from the repo root: crystal run --release scripts/crinja_corpus/bench_evaluators.cr
# (release build matters here - this is a perf measurement, not a
# correctness check).

require "../../src/krikri/variable_substitutor"

N = 200_000

vars = {
  "foo"   => JSON::Any.new("bar"),
  "items" => JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")] of JSON::Any),
  "count" => JSON::Any.new(5_i64),
  "flag"  => JSON::Any.new(true),
}

expressions = [
  "foo",
  "foo | upper",
  "count + 1",
  "flag and foo == 'bar'",
  "'yes' if flag else 'no'",
  "items | join(',')",
]

evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars)

crinja_vars = Hash(String, Crinja::Value).new
vars.each { |k, v| crinja_vars[k] = Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(v) }

env = Crinja.new
env.config.trim_blocks = true
env.config.lstrip_blocks = false

template_cache = Hash(String, Crinja::Template).new

def bench(label : String, n : Int32, &)
  start = Time.monotonic
  n.times { yield }
  elapsed = Time.monotonic - start
  per_call_ns = (elapsed.total_nanoseconds / n).round(1)
  puts "#{label.ljust(28)} total=#{elapsed.total_milliseconds.round(1)}ms  per_call=#{per_call_ns}ns"
end

expressions.each do |expr|
  puts "\n=== #{expr} ==="

  bench("hand-rolled", N) do
    evaluator.evaluate(expr)
  end

  src = "{{ #{expr} }}"

  bench("crinja (reparse each call)", N) do
    env.from_string(src).render(crinja_vars)
  end

  cached_template = template_cache.fetch(src) { template_cache[src] = env.from_string(src) }
  bench("crinja (parse-cached)", N) do
    cached_template.render(crinja_vars)
  end
end

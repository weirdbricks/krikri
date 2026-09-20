# One-off probe: do the two remaining hand-rolled-first arithmetic
# constructs (top-level `+` chains via #evaluate_plus, top-level `-`
# via #evaluate_minus) reproduce their exact current outputs when the
# WHOLE expression is delegated to Crinja (render_via_crinja_value +
# VariableLookup#format_value - the exact mechanics every already-
# converged construct uses)? Answers for the Phase 2 pilot report.
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

# The delegation pattern every converged construct uses: Crinja first,
# the EXACT hand-rolled path on any raise - so NEW must simulate that
# fallback too, not just the bare Crinja attempt.
def delegated(vars : Hash(String, JSON::Any), expr : String) : String
  value = Krikri::VariableSubstitutor::CrinjaRenderer.new(vars).evaluate_value!(expr)
  value ? Krikri::VariableSubstitutor::VariableLookup.new(vars).format_value(value) : "undefined"
rescue
  old_path(vars, expr)
end

def old_path(vars : Hash(String, JSON::Any), expr : String) : String
  Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(expr)
rescue e
  "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
end

vars = Hash(String, JSON::Any).new
vars["host"] = JSON::Any.new("web1")
vars["port"] = JSON::Any.new(8080_i64)
vars["ver"] = JSON::Any.new("2.27.0")
vars["ratio"] = JSON::Any.new(2.5)
vars["list1"] = JSON.parse(%(["a", "b"]))
vars["list2"] = JSON.parse(%(["c"]))
vars["emptylist"] = JSON.parse(%([]))
vars["item"] = JSON.parse(%({"name": "x"}))
vars["null_var"] = JSON::Any.new(nil)
vars["bt"] = JSON::Any.new(true)
vars["bf"] = JSON::Any.new(false)
vars["deep"] = JSON.parse(%({"inner": "{{ host }}"}))
vars["nested_list"] = JSON.parse(%([{"text": "{{ host }}"}]))
vars["ts_a"] = JSON::Any.new("2024-01-02 00:00:00")
vars["ts_b"] = JSON::Any.new("2024-01-01 00:00:00")

plus_cases = [
  %('a' + 'b'),
  %(host + '.example.com'),
  %('https://example.com/v' + ver + '/sums.txt'),
  %(port + 10),
  %(port + ratio),
  %(ratio + ratio),
  %(bt + bf),
  %(bt + 1),
  %(port + null_var),
  %(null_var + 'suffix'),
  %(host + null_var),
  %(list1 + list2),
  %(emptylist + list1),
  %(list1 + ['x']),
  %(item + list2),
  %(list1 + 3),
  %(item + item),
  %(host + port),
  %(port + host),
  %(deep),
  %(deep.inner + '!'),
  %(2 + 3 * 4),
  %(port * 2 + 1),
  %(host + omit),
  %(omit + host),
  %(-5 + 3),
  %(host + '/{{ sub }}'),
  %(missing_var + 'suffix'),
  %(port + missing_var),
  %(missing_var + missing_var2),
  %('' + host),
]

puts "=== `+` construct (OLD = current hand-rolled #evaluate_plus dispatch; NEW = whole-expr Crinja) ==="
plus_diverged = 0
plus_cases.each do |expr|
  o = old_path(vars, expr)
  n = delegated(vars, expr)
  mark = o == n ? "match" : "DIVERGE"
  plus_diverged += 1 unless o == n
  puts "  #{mark}  {{ #{expr} }}"
  puts "         OLD: #{o.inspect}" if o != n
  puts "         NEW: #{n.inspect}" if o != n
end
puts "  (#{plus_diverged} diverged of #{plus_cases.size})"

# Accumulator + re-templating shapes (real-role idioms, spec-adjacent)
puts "\n=== `+` real-role shapes ==="
[
  %(emptylist + [{'name': item.name}]),
  %(nested_list + nested_list),
  %(deep.inner + '_' + host),
].each do |expr|
  o = old_path(vars, expr)
  n = delegated(vars, expr)
  puts "  #{o == n ? "match" : "DIVERGE"}  {{ #{expr} }}"
  puts "       OLD: #{o.inspect}\n       NEW: #{n.inspect}" if o != n
end

minus_cases = [
  %(port - 10),
  %(port - ratio),
  %(ratio - ratio),
  %(bt - bf),
  %(bt - 1),
  %(port - null_var),
  %(null_var - 1),
  %(host - 'x'),
  %(host - host),
  %(list1 - list2),
  %(ts_a - ts_b),
  %(missing_var - 1),
  %((ts_a | to_datetime) - (ts_b | to_datetime)),
  %((ts_b | to_datetime) - (ts_a | to_datetime)),
]

puts "\n=== `-` construct (OLD = current hand-rolled #evaluate_minus dispatch; NEW = whole-expr Crinja) ==="
minus_diverged = 0
minus_cases.each do |expr|
  o = old_path(vars, expr)
  n = delegated(vars, expr)
  mark = o == n ? "match" : "DIVERGE"
  minus_diverged += 1 unless o == n
  puts "  #{mark}  {{ #{expr} }}"
  puts "         OLD: #{o.inspect}" if o != n
  puts "         NEW: #{n.inspect}" if o != n
end
puts "  (#{minus_diverged} diverged of #{minus_cases.size})"

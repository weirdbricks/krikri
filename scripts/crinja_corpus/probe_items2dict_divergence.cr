# Phase-3 Crinja consolidation slice #1 (items2dict) divergence probe.
# Runs the same battery against BOTH implementations of the name:
#   OLD = FilterEngine's hand-rolled JSON::Any dispatch (items_to_dict)
#   NEW = the native Crinja.filter(:items2dict) registration, invoked
#         through the exact #delegate_to_crinja_filter mechanics the
#         migration would use (so any divergence seen here is one the
#         bridge would expose).
# Run from the repo root:
#   crystal run scripts/crinja_corpus/probe_items2dict_divergence.cr
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

def old_path(value : JSON::Any, filter_expr : String) : String
  engine = Krikri::VariableSubstitutor::FilterEngine.new
  engine.apply(value, filter_expr).to_json
rescue e
  "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
end

# Real NEW path: parse kwargs from the filter expression like the case
# branch does (parse_kwarg on "key_name"/"value_name"), then delegate.
def crinja_call(value : JSON::Any, filter_args : String) : String
  key_name = "key"
  value_name = "value"
  if m = filter_args.match(/key_name\s*=\s*['"]([^'"]*)['"]/)
    key_name = m[1]
  end
  if m = filter_args.match(/value_name\s*=\s*['"]([^'"]*)['"]/)
    value_name = m[1]
  end
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters["items2dict"]
  kwargs = Crinja::Variables.new
  kwargs["key_name"] = Crinja::Value.new(key_name)
  kwargs["value_name"] = Crinja::Value.new(value_name)
  arguments = Crinja::Arguments.new(
    env,
    varargs: [] of Crinja::Value,
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

cases = [
  {"basic", %([{"key": "a", "value": 1}, {"key": "b", "value": 2}]), "items2dict"},
  {"empty list", %([]), "items2dict"},
  {"custom kwargs", %([{"name": "x", "data": "foo"}]), %(items2dict(key_name='name', value_name='data'))},
  {"custom key only", %([{"name": "x", "value": "foo"}]), %(items2dict(key_name='name'))},
  {"custom value only", %([{"key": "x", "data": "foo"}]), %(items2dict(value_name='data'))},
  {"collision later wins", %([{"key": "a", "value": 1}, {"key": "a", "value": 2}]), "items2dict"},
  {"non-dict item mixed", %([{"key": "a", "value": 1}, "junk", 3, null]), "items2dict"},
  {"missing key field", %([{"value": 1}, {"key": "b", "value": 2}]), "items2dict"},
  {"missing value field", %([{"key": "a"}, {"key": "b", "value": 2}]), "items2dict"},
  {"null value", %([{"key": "a", "value": null}]), "items2dict"},
  {"int value", %([{"key": "a", "value": 5}]), "items2dict"},
  {"bool value", %([{"key": "a", "value": true}]), "items2dict"},
  {"int key", %([{"key": 1, "value": "x"}]), "items2dict"},
  {"extra fields", %([{"key": "a", "value": 1, "extra": true}]), "items2dict"},
  {"input is dict not list", %({"a": 1}), "items2dict"},
  {"input is string", %("junk"), "items2dict"},
  {"input is null", %(null), "items2dict"},
  {"empty strings", %([{"key": "", "value": ""}]), "items2dict"},
  {"real-role shape (vars_result)", %([{"item": "max_connections", "ansible_facts": {"val": "100"}}]), %(items2dict(key_name='item', value_name='ansible_facts'))},
]

diverged = 0
cases.each do |(label, input_json, filter_expr)|
  input = JSON.parse(input_json)
  o = begin
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    engine.apply(input, filter_expr).to_json
  rescue e
    "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
  end
  n = crinja_call(input, filter_expr.sub("items2dict", "").strip)
  mark = o == n ? "match  " : "DIVERGE"
  diverged += 1 unless o == n
  puts "  #{mark} #{label}  | #{filter_expr}"
  puts "         input: #{input_json}"
  puts "         OLD: #{o}"
  puts "         NEW: #{n}" if o != n
end
puts "  (#{diverged} diverged of #{cases.size})"

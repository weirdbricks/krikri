# One-off probe: does a delegated-to-native selectattr reproduce the
# hand-rolled path's spec-locked behaviors? Answers for the pilot report.
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

def delegated(value : JSON::Any, expr : String) : JSON::Any?
  parts = expr.split(",").map(&.strip)
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters["selectattr"]
  varargs = [] of Crinja::Value
  parts.each do |part|
    parsed = JSON.parse(part) rescue JSON::Any.new(part.strip.delete("'\""))
    varargs << Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(parsed)
  end
  arguments = Crinja::Arguments.new(env, varargs: varargs, kwargs: Crinja::Variables.new,
    target: Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value))
  arguments.defaults = callable.defaults if callable.responds_to?(:defaults)
  Krikri::VariableSubstitutor::CrinjaRenderer.crinja_value_to_json_any(callable.call(arguments).as(Crinja::Value))
rescue e
  puts "  (delegated path raised: #{e.class}: #{e.message.to_s.split("\n").first})"
  nil
end

engine = Krikri::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)

puts "1. '==' test-name spelling (filter_engine_spec.cr:446 locks this):"
value = JSON.parse(%([{"path": "/a", "stat": {"exists": false}}, {"path": "/b", "stat": {"exists": true}}]))
old_result = engine.apply(value, %(selectattr('stat.exists', '==', True)))
new_result = delegated(value, "'stat.exists', '==', true")
puts "  OLD: #{old_result.as_a.size} item(s)"
puts "  NEW: #{new_result ? new_result.as_a.size : "RAISED"}"

puts "2. selectattr no-test default (hand-rolled: 'defined' presence check):"
value2 = JSON.parse(%([{"name": "a", "enabled": false}, {"name": "b", "enabled": true}]))
old_no_test = engine.apply(value2, %(selectattr('enabled')))
new_no_test = delegated(value2, "'enabled'")
puts "  OLD selectattr('enabled'): #{old_no_test.as_a.size} item(s) (defined-presence keeps the false one)"
puts "  NEW selectattr('enabled'): #{new_no_test ? new_no_test.as_a.size : "RAISED"} item(s) (native forks to truthy?)"

puts "3. {{ }}-bearing attribute re-templating (filter_engine_spec.cr:409 locks this):"
v = Hash(String, JSON::Any).new
v["security_package_state"] = JSON::Any.new("present")
engine_vars = Krikri::VariableSubstitutor::FilterEngine.new(v)
value3 = JSON.parse(%([{"state": "{{ security_package_state }}", "enabled": true}]))
old_retemplate = engine_vars.apply(value3, %(selectattr('state', 'equalto', 'present')))
new_retemplate = delegated(value3, "'state', 'equalto', 'present'")
puts "  OLD: #{old_retemplate.as_a.size} item(s)"
puts "  NEW: #{new_retemplate ? new_retemplate.as_a.size : "RAISED"} item(s) (raw {{ }} text can never equal 'present')"

puts "4. unknown test name (hand-rolled falls back to a defined check):"
value4 = JSON.parse(%([{"name": "a", "state": "present"}]))
old_unknown = engine.apply(value4, %(selectattr('state', 'madeuptest')))
new_unknown = delegated(value4, "'state', 'madeuptest'")
puts "  OLD selectattr('state', 'madeuptest'): #{old_unknown.as_a.size} item(s)"
puts "  NEW selectattr('state', 'madeuptest'): #{new_unknown ? new_unknown.as_a.size : "RAISED"}"

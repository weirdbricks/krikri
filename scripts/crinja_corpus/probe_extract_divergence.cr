# Phase-3 Crinja consolidation slice #4 (extract) divergence probe.
# Runs the same battery against BOTH implementations of the name:
#   OLD = FilterEngine's hand-rolled JSON::Any dispatch (the `case
#         filter_name` branch, also serving map()'s inner per-item path)
#   NEW = the native Crinja.filter(:extract) registration, invoked through
#         the same Arguments mechanics the Crinja-first chain path uses,
#         with hostvars shaped exactly like CrinjaRenderer.convert_hostvars
#         builds it (each host's dict wrapped in Krikri::HostVarsVarsDict).
# Arbitration oracle for every divergence: real ansible-core (2.19.11)
# via ansible-playbook debug renders (see the slice report; arbitration
# evidence per case cited inline below).
# Run from the repo root:
#   crystal run scripts/crinja_corpus/probe_extract_divergence.cr
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

def old_path(vars_json : Hash(String, String), value_json : String, filter_expr : String) : String
  vars = Hash(String, JSON::Any).new
  vars_json.each { |name, raw| vars[name] = JSON.parse(raw) }
  engine = Krikri::VariableSubstitutor::FilterEngine.new(vars)
  engine.apply(JSON.parse(value_json), filter_expr).to_json
rescue e
  "(raised: #{e.message.to_s.split("\n").first})"
end

# Hostvars exactly as the Crinja path sees it: a Crinja::Dictionary of
# per-host Krikri::HostVarsVarsDict wrappers (convert_hostvars's shape).
def crinja_hostvars(json_hostvars : JSON::Any) : Crinja::Value
  top = Crinja::Dictionary.new
  json_hostvars.as_h.each do |host, entry|
    entries = Hash(String, Crinja::Value).new
    entry.as_h.each do |k, v|
      entries[k] = Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(v)
    end
    top[Crinja::Value.new(host)] = Crinja::Value.new(Krikri::HostVarsVarsDict.new(entries))
  end
  Crinja::Value.new(top)
end

def crinja_container(name : String, vars_json : Hash(String, String)) : Crinja::Value
  raw = JSON.parse(vars_json[name])
  return crinja_hostvars(raw) if name == "hostvars"
  Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(raw)
end

def new_path(vars_json : Hash(String, String), value_json : String, container_name : String, morekeys_json : String?) : String
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters["extract"]
  varargs = [crinja_container(container_name, vars_json)]
  varargs << Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON.parse(morekeys_json)) if morekeys_json
  arguments = Crinja::Arguments.new(
    env,
    varargs: varargs,
    kwargs: Crinja::Variables.new,
    target: Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON.parse(value_json)),
  )
  arguments.defaults = callable.defaults if callable.responds_to?(:defaults)
  Krikri::VariableSubstitutor::CrinjaRenderer.crinja_value_to_json_any(
    callable.call(arguments).as(Crinja::Value)
  ).to_json
rescue e
  "(raised: #{e.message.to_s.split("\n").first})"
end

HOSTVARS = %({"host-a": {"node_ip": "10.0.0.1"}, "host-b": {"node_ip": "10.0.0.2"}})

# Each case: [label, vars, piped value, hand-rolled filter expression,
# Crinja container var name, Crinja morekeys (nil = absent)]. The
# hand-rolled expression and the container+morekeys encoding encode the
# same call. "real:" cites the live ansible-core 2.19.11 arbitration.
battery = [
  {"hostvars happy morekeys",
   {"hostvars" => HOSTVARS}, %q("host-a"), %q(extract(hostvars, 'node_ip')), "hostvars", %q("node_ip"),
   "real: 10.0.0.1"},
  {"hostvars missing attr via morekeys (T02, spec-locked)",
   {"hostvars" => HOSTVARS}, %q("host-a"), %q(extract(hostvars, 'ansible_host')), "hostvars", %q("ansible_host"),
   "real: raises object of type 'HostVarsVars' has no attribute 'ansible_host'"},
  {"hostvars direct, no morekeys (T04)",
   {"hostvars" => HOSTVARS}, %q("host-a"), %q(extract(hostvars)), "hostvars", nil,
   "real: the host's dict"},
  {"hostvars missing HOST (T03)",
   {"hostvars" => HOSTVARS}, %q("nosuchhost"), %q(extract(hostvars, 'node_ip')), "hostvars", %q("node_ip"),
   "real: raises hostvars['nosuchhost'] (path-naming marker; no type wording)"},
  {"plain dict present key (T05)",
   {"mapping" => %({"x": {"a": 1}})}, %q("x"), %q(extract(mapping)), "mapping", nil,
   "real: {a: 1}"},
  {"plain dict first-level miss (T06)",
   {"mapping" => %({"x": {"a": 1}})}, %q("zzz"), %q(extract(mapping)), "mapping", nil,
   "real: raises object of type 'dict' has no attribute 'zzz'"},
  {"plain dict morekeys miss (T07, spec-locked)",
   {"mapping" => %({"x": {"a": 1}})}, %q("x"), %q(extract(mapping, 'b')), "mapping", %q("b"),
   "real: raises object of type 'dict' has no attribute 'b'"},
  {"morekeys single string present (T08)",
   {"mapping" => %({"x": {"a": 1}})}, %q("x"), %q(extract(mapping, 'a')), "mapping", %q("a"),
   "real: 1"},
  {"morekeys list present (T09)",
   {"nested" => %({"x": {"a": {"b": 2}}})}, %q("x"), %q(extract(nested, ['a', 'b'])), "nested", %q(["a", "b"]),
   "real: 2"},
  {"morekeys list miss mid-walk (T10)",
   {"nested" => %({"x": {"a": {"b": 2}}})}, %q("x"), %q(extract(nested, ['zzz', 'b'])), "nested", %q(["zzz", "b"]),
   "real: raises object of type 'dict' has no attribute 'zzz'"},
  {"list int index happy (T11)",
   {"clist" => %(["zero", "one"])}, %q(1), %q(extract(clist)), "clist", nil,
   "real: one"},
  {"list index out of range (T12)",
   {"clist" => %(["zero", "one"])}, %q(5), %q(extract(clist)), "clist", nil,
   "real: raises object of type 'list' has no attribute 5"},
  {"list string key (T13)",
   {"clist" => %(["zero", "one"])}, %q("abc"), %q(extract(clist)), "clist", nil,
   "real: raises object of type 'list' has no attribute 'abc'"},
  {"list negative index",
   {"clist" => %(["zero", "one"])}, %q(-1), %q(extract(clist)), "clist", nil,
   "real: one (Python list[-1])"},
  {"string container (T14)",
   {"scalar_str" => %("hello")}, %q("x"), %q(extract(scalar_str)), "scalar_str", nil,
   "real: raises object of type 'str' has no attribute 'x'"},
  {"string container int-indexed",
   {"scalar_str" => %("hello")}, %q(1), %q(extract(scalar_str)), "scalar_str", nil,
   "real: e (Python 'hello'[1])"},
  {"string container int-indexed out of range",
   {"scalar_str" => %("hi")}, %q(9), %q(extract(scalar_str)), "scalar_str", nil,
   "real: raises object of type 'str' has no attribute 9"},
  {"null container, defined (T15b)",
   {"nullvar" => %(null)}, %q("x"), %q(extract(nullvar)), "nullvar", nil,
   "real: raises object of type 'NoneType' has no attribute 'x'"},
  {"bool container",
   {"bvar" => %(true)}, %q("x"), %q(extract(bvar)), "bvar", nil,
   "real: raises object of type 'bool' has no attribute 'x'"},
  {"morekeys onto non-dict acc (T16)",
   {"mapping" => %({"x": {"a": 1}})}, %q("x"), %q(extract(mapping, ['a', 'b'])), "mapping", %q(["a", "b"]),
   "real: raises object of type 'int' has no attribute 'b'"},
  {"morekeys int-indexes into a list (T17)",
   {"clist" => %(["zero", "one"])}, %q(0), %q(extract(clist, [0])), "clist", %q([0]),
   "real: z (clist[0] then 'zero'[0])"},
  {"morekeys single int indexes twice",
   {"clist" => %(["zero", "one"])}, %q(0), %q(extract(clist, 0)), "clist", %q(0),
   "real: z (keys [0, 0])"},
  {"int piped value on dict (T18)",
   {"mapping" => %({"x": {"a": 1}})}, %q(5), %q(extract(mapping)), "mapping", nil,
   "real: raises object of type 'dict' has no attribute 5 (int keys unquoted)"},
  {"int key hits string-keyed dict (coercion deviation)",
   {"m" => %({"5": "v"})}, %q(5), %q(extract(m)), "m", nil,
   "real: raises object of type 'dict' has no attribute 5; krikri coerces to \"5\" (JSON-engine representation leniency, kept)"},
  {"morekeys null = absent (real: morekeys is None)",
   {"mapping" => %({"x": {"a": 1}})}, %q("x"), %q(extract(mapping, none)), "mapping", %q(null),
   "real: {a: 1} (None morekeys treated as absent)"},
  {"empty morekeys list",
   {"mapping" => %({"x": {"a": 1}})}, %q("x"), %q(extract(mapping, [])), "mapping", %q([]),
   "real: {a: 1}"},
]

diverged = 0
battery.each do |(label, vars_json, value_json, old_expr, container_name, morekeys_json, oracle)|
  o = old_path(vars_json, value_json, old_expr)
  n = new_path(vars_json, value_json, container_name, morekeys_json)
  mark = o == n ? "match  " : "DIVERGE"
  diverged += 1 unless o == n
  puts "  #{mark} #{label}"
  puts "         value: #{value_json}  expr: #{old_expr}"
  puts "         OLD: #{o}"
  puts "         NEW: #{n}" if o != n
  puts "         #{oracle}"
end
puts "  (#{diverged} diverged of #{battery.size})"

# Phase-3 Crinja consolidation slice #2 (ternary) divergence probe.
# Runs the same battery against BOTH implementations of the name:
#   OLD = FilterEngine's hand-rolled JSON::Any dispatch (the "ternary"
#         case branch, with its bare-omit -> OMIT_SENTINEL handling)
#   NEW = the native Crinja.filter(:ternary) registration (jinja_filters.cr),
#         invoked through the exact #delegate_to_crinja_filter mechanics the
#         migration uses - arguments pre-resolved from the filter-arg text
#         (bare `omit` mapped to the sentinel, everything else through
#         #resolve_expression) exactly like the delegated case branch does,
#         so any divergence seen here is one the bridge would expose.
# Arbitration oracle: real ansible-core 2.19.11 (ansible/plugins/filter/
# core.py's ternary), probed live - see the slice report in
# CRINJA_PHASE3_SURVEY.md.
# Run from the repo root:
#   crystal run scripts/crinja_corpus/probe_ternary_divergence.cr
require "json"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

def old_path(value : JSON::Any, filter_expr : String, vars) : String
  engine = Krikri::VariableSubstitutor::FilterEngine.new(vars)
  engine.apply(value, filter_expr).to_json
rescue e
  "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
end

# The exact shape the migrated case branch uses: split the arg text,
# map bare `omit` to the sentinel, resolve everything else, then hand the
# varargs to the ONE native registration through the bridge converters.
# The battery's arg grammar is quoted literals, bare boolean/null literals
# and variable names - resolved here to the same values FilterEngine's
# #resolve_expression produces for them (a bareword that misses every
# variable resolves to null, exactly like a VariableLookup miss).
def resolve_arg(arg : String, vars) : JSON::Any
  if (arg.starts_with?('"') && arg.ends_with?('"')) ||
     (arg.starts_with?("'") && arg.ends_with?("'"))
    return JSON::Any.new(arg[1..-2])
  end
  return JSON::Any.new(true) if arg == "true"
  return JSON::Any.new(false) if arg == "false"
  return JSON::Any.new(nil) if arg == "null" || arg == "None"
  return vars[arg] if vars.has_key?(arg)
  JSON::Any.new(nil)
end

def new_path(value : JSON::Any, filter_args : String, vars) : String
  args = filter_args.split(',').map(&.strip).reject(&.empty?)
  varargs = args.map { |arg| arg == "omit" ? JSON::Any.new(Krikri::OMIT_SENTINEL) : resolve_arg(arg, vars) }
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters["ternary"]
  arguments = Crinja::Arguments.new(
    env,
    varargs: varargs.map { |arg| Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(arg) },
    kwargs: Crinja::Variables.new,
    target: Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value),
  )
  arguments.defaults = callable.defaults if callable.responds_to?(:defaults)
  Krikri::VariableSubstitutor::CrinjaRenderer.crinja_value_to_json_any(
    callable.call(arguments).as(Crinja::Value)
  ).to_json
rescue e
  "(raised: #{e.class}: #{e.message.to_s.split("\n").first})"
end

VARS = {
  "undef_var" => JSON.parse("null"),
  "some_var"  => JSON.parse("\"picked-var\""),
} of String => JSON::Any

cases = [
  {"true condition", %(true), %('yes', 'no')},
  {"false condition", %(false), %('yes', 'no')},
  {"int 1 condition", %(1), %('yes', 'no')},
  {"int 0 condition", %(0), %('yes', 'no')},
  {"float 0.0 condition", %(0.0), %('yes', 'no')},
  {"empty string", %(""), %('yes', 'no')},
  {"string 0", %("0"), %('yes', 'no')},
  {"string false", %("false"), %('yes', 'no')},
  {"string False", %("False"), %('yes', 'no')},
  {"string no", %("no"), %('yes', 'no')},
  {"empty list", %([]), %('yes', 'no')},
  {"non-empty list", %([1]), %('yes', 'no')},
  {"empty dict", %({}), %('yes', 'no')},
  {"null condition", %(null), %('yes', 'no')},
  {"null cond + 3rd arg", %(null), %('yes', 'no', 'n/a')},
  {"true cond + 3rd arg", %(true), %('yes', 'no', 'n/a')},
  {"omit in false branch", %(false), %('x', omit)},
  {"omit in true branch", %(true), %(omit, 'no')},
  {"quoted 'omit' literal", %(false), %('x', 'omit')},
  {"sentinel cond value", %("__crystal_ansible_omit__"), %('yes', 'no')},
  {"missing false arg", %(false), %('yes')},
  {"missing both args", %(true), ""},
  {"unchosen undef var", %(true), %('yes', undef_var)},
  {"chosen var ref", %(true), %(some_var, 'no')},
]

diverged = 0
cases.each do |(label, value_json, filter_args)|
  value = JSON.parse(value_json)
  o = old_path(value, "ternary(#{filter_args})", VARS)
  n = new_path(value, filter_args, VARS)
  mark = o == n ? "match  " : "DIVERGE"
  diverged += 1 unless o == n
  puts "  #{mark} #{label}"
  puts "         input: ternary(#{filter_args}) on #{value_json}"
  puts "         OLD: #{o}"
  puts "         NEW: #{n}" if o != n
end
puts "  (#{diverged} diverged of #{cases.size})"

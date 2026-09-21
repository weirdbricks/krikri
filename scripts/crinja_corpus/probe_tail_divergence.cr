# Phase-3 Crinja consolidation slice #5 (low-frequency tail) divergence probe.
# Runs one combined battery against BOTH implementations of each tail filter:
#   OLD = FilterEngine's hand-rolled JSON::Any dispatch (the filter's own
#         case branch, pre-migration)
#   NEW = the native Crinja.filter registration (jinja_filters.cr), invoked
#         through the exact #delegate_to_crinja_filter mechanics the migrated
#         case branch uses - positional varargs + named kwargs pre-resolved
#         from the filter-arg text exactly like the delegated branch does.
# Arbitration oracle: real ansible-core 2.19.11, probed live via
# /tmp/crinja-tail-oracle (playbook + extracted facts in oracle.json) - see
# the slice report in CRINJA_PHASE3_SURVEY.md.
# Run from the repo root:
#   crystal run scripts/crinja_corpus/probe_tail_divergence.cr
require "json"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/jinja_filters"

def old_path(value : JSON::Any, filter_expr : String) : String
  engine = Krikri::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)
  engine.apply(value, filter_expr).to_json
rescue e
  "(raised: #{e.message.to_s.split("\n").first})"
end

# Mimics the resolver the migrated case branches use (#resolve_expression):
# quoted literals, numbers, bools, null, and simple list literals.
LITERALS = {"true" => true, "false" => false, "null" => nil, "None" => nil}

def resolve_arg(arg : String) : JSON::Any
  arg = arg.strip
  if (arg.starts_with?('"') && arg.ends_with?('"')) ||
     (arg.starts_with?("'") && arg.ends_with?("'"))
    return JSON::Any.new(arg[1..-2])
  end
  return JSON::Any.new(LITERALS[arg]) if LITERALS.has_key?(arg)
  return JSON::Any.new(arg.to_i64) if arg =~ /^\d+$/
  return JSON::Any.new(arg.to_f) if arg =~ /^\d+\.\d+$/
  return JSON.parse(arg) if arg.starts_with?('[') && arg.ends_with?(']')
  JSON::Any.new(arg)
end

# Splits on top-level commas (brackets/quotes aware) - the
# #split_top_level_args grammar the case branches use.
def split_args(filter_args : String) : Array(String)
  parts = [] of String
  depth = 0
  quote = nil
  current = String::Builder.new
  filter_args.each_char do |char|
    if quote
      current << char
      quote = nil if char == quote
    elsif char == '\'' || char == '"'
      quote = char
      current << char
    elsif char == '[' || char == '{'
      depth += 1
      current << char
    elsif char == ']' || char == '}'
      depth -= 1
      current << char
    elsif char == ',' && depth == 0
      parts << current.to_s.strip
      current = String::Builder.new
    else
      current << char
    end
  end
  last = current.to_s.strip
  parts << last unless last.empty?
  parts
end

# The arg-splitting shape every migrated tail branch uses: positional
# varargs plus `name=`-prefixed kwargs, values resolved like
# #resolve_expression resolves them.
def parse_args(filter_args : String)
  positional = [] of JSON::Any
  kwargs = Crinja::Variables.new
  split_args(filter_args).each do |part|
    if (m = part.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/m)) && m[1] != "x"
      kwargs[m[1]] = Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(resolve_arg(m[2]))
    else
      positional << resolve_arg(part)
    end
  end
  {positional, kwargs}
end

def new_path(value : JSON::Any, name : String, filter_args : String) : String
  positional, kwargs = parse_args(filter_args)
  env = Krikri::VariableSubstitutor::CrinjaRenderer.shared_environment
  callable = env.filters[name]
  arguments = Crinja::Arguments.new(
    env,
    varargs: positional.map { |arg| Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(arg) },
    kwargs: kwargs,
    target: Krikri::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value),
  )
  arguments.defaults = callable.defaults if callable.responds_to?(:defaults)
  Krikri::VariableSubstitutor::CrinjaRenderer.crinja_value_to_json_any(
    callable.call(arguments).as(Crinja::Value)
  ).to_json
rescue e
  "(raised: #{e.message.to_s.split("\n").first})"
end

ORACLE = Hash(String, JSON::Any).from_json(File.read("/tmp/crinja-tail-oracle/oracle.json"))

# {label, filter name, filter args, value, oracle key (nil = no deterministic oracle)}
cases = [
  # zip / zip_longest / product
  {"zip 2-way", "zip", "[3,4]", JSON.parse("[1,2]"), "zip2"},
  {"zip 3-way", "zip", "[2],[3]", JSON.parse("[1]"), "zip3"},
  {"zip 4-way", "zip", "[2],[3],[4]", JSON.parse("[1]"), "zip4"},
  {"zip uneven", "zip", "[3]", JSON.parse("[1,2]"), nil},
  {"zip_longest fillvalue kwarg", "zip_longest", "[3], fillvalue='-'", JSON.parse("[1,2]"), "zlong"},
  {"zip_longest positional third list", "zip_longest", "[3], '-'", JSON.parse("[1,2]"), "zlong_posfill"},
  {"zip_longest no fillvalue", "zip_longest", "[3]", JSON.parse("[1,2]"), nil},
  {"product 2 lists", "product", "[3,4]", JSON.parse("[1,2]"), "prod"},
  {"product single arg", "product", "[3]", JSON.parse("[1,2]"), nil},
  {"zip empty value", "zip", "[3,4]", JSON.parse("[]"), nil},
  {"zip non-list arg", "zip", "'ab'", JSON.parse("[1]"), nil},
  # combinations / permutations
  {"combinations n=2", "combinations", "2", JSON.parse("[1,2,3]"), "comb"},
  {"combinations n=1", "combinations", "1", JSON.parse("[1,2,3]"), nil},
  {"combinations n>size", "combinations", "5", JSON.parse("[1,2]"), nil},
  {"combinations n=0", "combinations", "0", JSON.parse("[1,2]"), nil},
  {"combinations empty", "combinations", "2", JSON.parse("[]"), nil},
  {"combinations default n", "combinations", "", JSON.parse("[1,2,3]"), nil},
  {"permutations default", "permutations", "", JSON.parse("[1,2]"), "perm"},
  {"permutations n=1", "permutations", "1", JSON.parse("[1,2]"), "perm1"},
  {"permutations n>size", "permutations", "3", JSON.parse("[1,2]"), nil},
  {"permutations empty", "permutations", "", JSON.parse("[]"), nil},
  # rekey_on_member
  {"rekey basic", "rekey_on_member", "'name'", JSON.parse("[{\"name\":\"a\",\"v\":1},{\"name\":\"b\",\"v\":2}]"), "rekey"},
  {"rekey numeric key", "rekey_on_member", "'id'", JSON.parse("[{\"id\":5,\"v\":1}]"), "rekey_num"},
  {"rekey duplicates positional", "rekey_on_member", "'name', 'overwrite'", JSON.parse("[{\"name\":\"a\",\"v\":1}]"), "rekey_posdup"},
  {"rekey duplicates kwarg", "rekey_on_member", "'name', duplicates='overwrite'", JSON.parse("[{\"name\":\"a\",\"v\":1}]"), "rekey_kwdup"},
  {"rekey empty list", "rekey_on_member", "'name'", JSON.parse("[]"), nil},
  {"rekey non-dict item", "rekey_on_member", "'name'", JSON.parse("[1,2]"), nil},
  {"rekey missing member field", "rekey_on_member", "'name'", JSON.parse("[{\"v\":1}]"), nil},
  # from_yaml_all
  {"from_yaml_all multi-doc", "from_yaml_all", "", JSON.parse("\"a: 1\\n---\\nb: 2\""), "fya"},
  {"from_yaml_all empty", "from_yaml_all", "", JSON.parse("\"\""), "fya_empty"},
  {"from_yaml_all leading ---", "from_yaml_all", "", JSON.parse("\"---\\na: 1\""), "fya_lead"},
  {"from_yaml_all single doc", "from_yaml_all", "", JSON.parse("\"a: 1\""), "fya_single"},
  {"from_yaml_all scalar doc", "from_yaml_all", "", JSON.parse("\"42\""), nil},
  {"from_yaml_all invalid", "from_yaml_all", "", JSON.parse("\"a: [\""), nil},
  # relpath
  {"relpath positional start", "relpath", "'/a'", JSON.parse("\"/a/b/c\""), "rel"},
  {"relpath start= kwarg", "relpath", "start='/a'", JSON.parse("\"/a/b/c\""), "rel_kw"},
  {"relpath same path", "relpath", "'/a/b'", JSON.parse("\"/a/b\""), "rel_same"},
  {"relpath default start", "relpath", "", JSON.parse("\"/a/b/c\""), nil},
  {"relpath relative path", "relpath", "'/a'", JSON.parse("\"b/c\""), nil},
  # log / pow
  {"log positional base", "log", "2", JSON.parse("8.0"), "log2"},
  {"log base= kwarg", "log", "base=2", JSON.parse("8.0"), "log_kw"},
  {"log natural", "log", "", JSON.parse("8.0"), "log_nat"},
  {"log int target", "log", "2", JSON.parse("8"), nil},
  {"pow positional", "pow", "10", JSON.parse("2.0"), "pow"},
  {"pow int target", "pow", "10", JSON.parse("2"), nil},
  {"pow zero exponent", "pow", "0", JSON.parse("2.0"), nil},
  {"pow negative exponent", "pow", "-2", JSON.parse("2.0"), nil},
]

diverged = 0
oracle_diverged = 0
cases.each do |label, name, filter_args, value, oracle_key|
  o = old_path(value, filter_args.empty? ? name : "#{name}(#{filter_args})")
  n = new_path(value, name, filter_args)
  mark = o == n ? "match  " : "DIVERGE"
  unless o == n
    diverged += 1
    puts "  #{mark} #{label}"
    puts "         input: #{name}(#{filter_args}) on #{value.to_json}"
    puts "         OLD: #{o}"
    puts "         NEW: #{n}"
  end
  next unless oracle_key
  want = ORACLE[oracle_key].to_json
  if n != want
    oracle_diverged += 1
    puts "  ORACLE-DIVERGE #{label}: real=#{want} new=#{n}"
  end
end
puts "  (#{diverged} old-vs-new diverged, #{oracle_diverged} new-vs-real diverged, of #{cases.size} cases)"

# random: shape contract only (nondeterministic unseeded; PyRandom-exact seeded)
puts "\n  random (shape contract):"
[{"65534 | random(seed='host1')", JSON.parse("65534"), "seed=65534? no - string"},
].clear
seeded_int_old = old_path(JSON.parse("65534"), "random(seed='host1')")
seeded_int_new = new_path(JSON.parse("65534"), "random", "seed='host1'")
puts "  seeded int 65534/host1: OLD=#{seeded_int_old} NEW=#{seeded_int_new} (real=31863)"
abort "seeded random diverges!" if seeded_int_old != seeded_int_new || seeded_int_new != "31863"
seeded_list_old = old_path(JSON.parse(%(["a","b","c"])), "random(seed='host1')")
seeded_list_new = new_path(JSON.parse(%(["a","b","c"])), "random", "seed='host1'")
puts "  seeded list/host1: OLD=#{seeded_list_old} NEW=#{seeded_list_new} (real=\"b\")"
abort "seeded list random diverges!" if seeded_list_old != seeded_list_new || seeded_list_new != "\"b\""
seeded_str_old = old_path(JSON.parse(%("abcde")), "random(seed='host1')")
seeded_str_new = new_path(JSON.parse(%("abcde")), "random", "seed='host1'")
puts "  seeded string/host1: OLD=#{seeded_str_old} NEW=#{seeded_str_new} #{seeded_str_old == seeded_str_new ? "match" : "DIVERGE"}"
empty_old = old_path(JSON.parse("[]"), "random")
empty_new = new_path(JSON.parse("[]"), "random", "")
puts "  empty list: OLD=#{empty_old} NEW=#{empty_new} #{empty_old == empty_new ? "match" : "DIVERGE"}"
zero_old = old_path(JSON.parse("0"), "random")
zero_new = new_path(JSON.parse("0"), "random", "")
puts "  int 0: OLD=#{zero_old} NEW=#{zero_new} #{zero_old == zero_new ? "match" : "DIVERGE"}"
unseeded_ints = [1, 2, 3].map { new_path(JSON.parse("100"), "random", "").to_i? }
puts "  unseeded int x3: #{unseeded_ints} #{unseeded_ints.uniq.size > 1 ? "(nondeterministic, good)" : "(ALL SAME - suspicious)"}"
puts "  unseeded in range: #{unseeded_ints.all? { |i| i && i >= 0 && i < 100 ? "yes" : "NO" }}"

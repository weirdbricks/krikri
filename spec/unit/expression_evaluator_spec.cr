require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/expression_evaluator"

describe CrystalPlay::VariableSubstitutor::ExpressionEvaluator do
  it "dispatches simple lookups" do
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("ada")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("name").should eq("ada")
  end

  it "dispatches nested lookups" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("user.name").should eq("ada")
  end

  it "dispatches indexed access" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("items[0]").should eq("a")
  end

  it "dispatches comparisons before filters" do
    v = Hash(String, JSON::Any).new
    v["rc"] = JSON::Any.new(0_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("rc == 0").should eq("true")
  end

  it "applies a filter to a simple variable" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(missing | default('fallback'))).should eq("fallback")
  end

  it "evaluates a filter combined with a comparison in the same expression" do
    # Real, previously-shipped bug: has_comparison? matched before the `|`
    # check, so `mylist | length > 0` routed entirely to
    # ComparisonEvaluator with the filter chain still attached to the
    # operand text, which it had no way to evaluate - this always
    # returned "false" regardless of the actual list, in *any* {{ }}
    # substitution context (debug: msg:, when:, etc.), not just when:'s
    # own bare-conditional path.
    v = Hash(String, JSON::Any).new
    v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("mylist | length > 0").should eq("true")

    v["mylist"] = JSON::Any.new([] of JSON::Any)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("mylist | length > 0").should eq("false")
  end

  it "evaluates range(stop) with the | list filter, matching Python's range()" do
    # Real bug found benchmarking a perf playbook: `loop: "{{ range(1, 11)
    # | list }}"` silently resolved to nil (fell through to plain variable
    # lookup on the literal text "range(1, 11)", always undefined),
    # running the loop body once with `item` undefined instead of 10
    # times.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(3) | list").should eq(%([0,1,2]))
  end

  it "evaluates bare range(stop) with no filter at all" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(3)").should eq(%([0,1,2]))
  end

  it "evaluates range(start, stop)" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(1, 11) | list").should eq(%([1,2,3,4,5,6,7,8,9,10]))
  end

  it "evaluates range(start, stop, step) including a negative step" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(0, 10, 2) | list").should eq(%([0,2,4,6,8]))
    evaluator.evaluate("range(5, 0, -1) | list").should eq(%([5,4,3,2,1]))
  end

  it "evaluates range() arguments that are themselves variables" do
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new(4_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(1, n) | list").should eq(%([1,2,3]))
  end

  it "defaults lookup('first_found', ...) with no paths: to the current role's vars/ dir" do
    # Real bug found benchmarking geerlingguy.docker/mysql/postgresql/php,
    # which all share this exact idiom: `include_vars: "{{
    # lookup('first_found', params) }}"` with `vars: params: {files:
    # [...]}` and NO `paths:` at all - relying entirely on first_found's
    # own default search roots to find an OS-specific file living in the
    # role's own vars/ dir. Previously defaulted unconditionally to ".",
    # ignoring role context entirely, so the task always failed with
    # "file not found: undefined" for every role using this pattern.
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_role_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "still honors an explicit absolute paths: entry, unaffected by role-relative resolution" do
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_explicit_paths_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "otherdir"))
    File.write(File.join(role_dir, "otherdir", "x.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["x.yml"], "paths": [#{File.join(role_dir, "otherdir").to_json}]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "otherdir", "x.yml"))
  end

  it "resolves an explicit relative paths: entry against the role dir, not cwd" do
    # The actual real-world spelling that broke geerlingguy.docker/mysql/
    # postgresql: `paths: ['vars']`, an explicit but RELATIVE entry -
    # previously joined straight against the process's cwd
    # ("vars/Debian.yml"), essentially never the role's own vars/ dir a
    # real ansible-playbook run resolves it against.
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_relative_paths_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["vars"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "vars", "Debian.yml"))
  end
end

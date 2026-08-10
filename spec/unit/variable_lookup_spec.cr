require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/variable_lookup"

describe CrystalPlay::VariableSubstitutor::VariableLookup do
  it "resolves a simple string variable and strips whitespace" do
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("  hello  ")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.simple("name").should eq("hello")
  end

  it "returns 'undefined' for a missing simple variable" do
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(Hash(String, JSON::Any).new)
    lookup.simple("missing").should eq("undefined")
  end

  it "resolves nested hash access" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("user.name").should eq("ada")
  end

  it "returns 'undefined' for a missing nested key" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("user.email").should eq("undefined")
  end

  it "resolves numeric array indexing" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c"]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("items[1]").should eq("b")
  end

  it "resolves quoted hash key indexing" do
    v = Hash(String, JSON::Any).new
    v["config"] = JSON.parse(%({"host": "example.com"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed(%(config['host'])).should eq("example.com")
  end

  # Booleans rendered directly into template text (`{{ boolvar }}`) must
  # come out as Python/Jinja2's capitalized "True"/"False", not Crystal's
  # lowercase "true"/"false" - verified against real ansible-playbook (a
  # `copy: content:` with `{{ stat_result.stat.exists }}` renders "True").
  # This is distinct from ComparisonEvaluator's own internal "true"/"false"
  # protocol used for `when:` truthiness, which already tolerates both
  # cases and is untouched here.
  it "renders a boolean as capitalized True/False via simple lookup" do
    v = Hash(String, JSON::Any).new
    v["yes_flag"] = JSON::Any.new(true)
    v["no_flag"] = JSON::Any.new(false)
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.simple("yes_flag").should eq("True")
    lookup.simple("no_flag").should eq("False")
  end

  it "renders a boolean as True/False via nested lookup" do
    v = Hash(String, JSON::Any).new
    v["stat"] = JSON.parse(%({"exists": true, "isdir": false}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("stat.exists").should eq("True")
    lookup.nested("stat.isdir").should eq("False")
  end

  it "renders a boolean as True/False via indexed access" do
    v = Hash(String, JSON::Any).new
    v["flags"] = JSON.parse(%([true, false]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("flags[0]").should eq("True")
    lookup.indexed("flags[1]").should eq("False")
  end

  it "resolves a Python-style .split(sep)[index] method call chained off a dotted path" do
    # Real bug found benchmarking geerlingguy.postgresql's own "Include
    # OS-specific variables (Debian)." task: `include_vars: "{{
    # ansible_facts.distribution }}-{{ ansible_facts.distribution_version
    # .split('.')[0] }}.yml"`. Two compounding gaps: resolve_nested's
    # naive `expr.split(".")` broke on the METHOD ARGUMENT's own literal
    # "." (splitting "split('.')" into two garbled parts instead of
    # leaving it whole), and even with that fixed, no String method-call
    # handling existed at all (only Hash's .keys()/.values()/.items()) -
    # together these always resolved to "undefined" ("Ubuntu-undefined.
    # yml" instead of "Ubuntu-22.yml").
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"distribution_version": "22.04"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("ansible_facts.distribution_version.split('.')[0]").should eq("22")
    lookup.indexed("ansible_facts.distribution_version.split('.')[1]").should eq("04")
  end
end

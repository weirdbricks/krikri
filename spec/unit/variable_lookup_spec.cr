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

  it "resolves character indexing on a plain string, matching real Jinja2/Python str[0]" do
    # Real bug found benchmarking geerlingguy.elasticsearch: its own
    # version-branch `when: elasticsearch_version[0] | int < 7` (on
    # elasticsearch_version: "7.x", a plain string) fell through
    # index_into's `else -> nil` case (only Array/Hash were handled),
    # `| int` on the resulting "undefined" defaulted to 0, and `0 < 7`
    # silently picked the WRONG config-file layout (pre-7.x
    # elasticsearch.yml/jvm.options instead of 7+'s
    # jvm.options.d/heap.options) - Elasticsearch then failed to start
    # against the mismatched config.
    v = Hash(String, JSON::Any).new
    v["version"] = JSON::Any.new("7.x")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("version[0]").should eq("7")
    lookup.indexed("version[1]").should eq(".")
  end

  it "resolves negative character indexing on a plain string" do
    v = Hash(String, JSON::Any).new
    v["version"] = JSON::Any.new("7.x")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("version[-1]").should eq("x")
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

  it "walks a .attr suffix after an [index], not just the index alone" do
    # Real bug found benchmarking openstack.ansible-hardening's own AIDE-
    # config guard: `when: aide_conf.results[0].stat.exists | bool`, a
    # registered LOOPED task's aggregated results, indexed then walked
    # further. resolve_indexed's old bracket-only regex scan had no
    # notion of anything after the final "]" - `results[0].stat.exists`
    # resolved to the *whole* results[0] hash instead of its nested
    # boolean. Piped through `| bool` in a when:, any non-empty rendered
    # hash is truthy, so a should-have-been-skipped task ran for real.
    v = Hash(String, JSON::Any).new
    v["aide_conf"] = JSON.parse(%({"results": [{"item": "/etc/aide.conf", "stat": {"exists": false}}]}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("aide_conf.results[0].stat.exists").should eq("False")

    # Indexing alone (no trailing suffix) still resolves the item itself.
    lookup.indexed("aide_conf.results[0].item").should eq("/etc/aide.conf")
  end
end

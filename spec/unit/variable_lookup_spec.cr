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

  it "resolves a Python-style .find(substring) method call on a string" do
    # Real bug found benchmarking geerlingguy.clamav's own "Run freshclam
    # after ClamAV packages change." task: `failed_when: - freshclam_
    # result is failed - freshclam_result.stderr.find('locked by
    # another process') != -1` (only override the command module's own
    # default nonzero-exit failure when THAT specific message is
    # present - Debian's post-install freshclam run means a plain
    # nonzero exit here is expected and not a real failure). No String
    # method-call handling existed for `.find(...)` at all (only
    # `.split(...)`) - resolve_nested's fallthrough (current isn't a
    # Hash) returned nil/undefined, and `undefined != -1` evaluated
    # true, so failed_when always fired regardless of the actual
    # message - real ansible-playbook's own run of the identical role
    # reports this task as "changed", not failed.
    v = Hash(String, JSON::Any).new
    v["r"] = JSON.parse(%({"stdout": "hello world"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("r.stdout.find('world')").should eq("6")
    lookup.nested("r.stdout.find('nope')").should eq("-1")
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

  it "resolves a no-argument .split() method call, splitting on whitespace runs like real Python" do
    # Real bug found benchmarking robertdebock.bootstrap's own `loop: "{{
    # bootstrap_facts_packages.split() }}"` (round 18). Only the quoted-
    # separator form (`.split('sep')`, fixed above for geerlingguy.
    # postgresql) matched string_method_call's regex - the bare no-arg
    # form fell through entirely (current stays a String, not a Hash,
    # so the dotted-access fallthrough returns nil/undefined), turning a
    # 4-package loop into a single bogus "undefined" item that then
    # failed to install as a real package name.
    v = Hash(String, JSON::Any).new
    v["pkgs"] = JSON::Any.new("python3 sudo gnupg python3-apt")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    result = lookup.resolve("pkgs.split()")
    result.should_not be_nil
    result.not_nil!.as_a.map(&.as_s).should eq(["python3", "sudo", "gnupg", "python3-apt"])
  end

  it "re-renders a dotted-access BASE variable that is itself still-unrendered {{ }} text before walking .method()/.attr off of it" do
    # Real Ansible's recursive re-templating - one more independent copy
    # of this bug class (already fixed at several OTHER call sites: the
    # bare-lookup fallback, the filter-chain head, default()'s own
    # argument, a bare comparison operand), this time for the dotted-
    # access BASE fetch specifically. Found via robertdebock.bootstrap's
    # own `bootstrap_facts_packages: "{{ _bootstrap_packages[...] |
    # default(...) }}"` (vars/main.yml, round 18): the var is stored in
    # @vars still as its own raw `{{ }}` text (lazy evaluation), and
    # resolve_nested previously fetched that literal text as-is and
    # called `.split()` directly on it instead of on its real rendered
    # value.
    v = Hash(String, JSON::Any).new
    v["inner"] = JSON::Any.new("hello world")
    v["outer"] = JSON::Any.new("{{ inner }}")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    result = lookup.resolve("outer.split()")
    result.should_not be_nil
    result.not_nil!.as_a.map(&.as_s).should eq(["hello", "world"])
  end
end

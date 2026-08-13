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

  it "evaluates a quoted string literal piped into a filter chain" do
    # `{{ 'foo' | upper }}` - a literal, not a variable, as the chain's
    # head. Previously the base-value resolution in evaluate_with_filter
    # only understood a bare variable name, `(...)`, `range(...)`, or
    # `[...]` indexing as the chain's head - a quoted literal fell to the
    # plain-lookup fallback, treating the literal text (quotes included)
    # as a variable NAME to resolve, always undefined.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'hello' | upper").should eq("HELLO")
    evaluator.evaluate("'/var/log/mysql/mysql.err' | dirname").should eq("/var/log/mysql")
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

  it "evaluates lookup('env', 'VAR') for both a set and an unset environment variable" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version: "{{ lookup('env', 'VAULT_VERSION') | default(
    # '2.0.3', true) }}"` - lookup('env', ...) was entirely unimplemented
    # (only 'first_found' was), always "undefined" regardless of the
    # real env var.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    ENV["CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST"] = "hello"
    evaluator.evaluate("lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST')").should eq("hello")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST")

    evaluator.evaluate("lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST')").should eq("")
  end

  it "resolves lookup(...) followed by a filter chain, not swallowing the whole thing as one bare call" do
    # Real bug found alongside the env lookup above: `lookup('env',
    # 'VAULT_VERSION') | default('2.0.3', true)` - the naive `starts_with
    # ("lookup(") && ends_with(')')` check in evaluate_expr matched the
    # *whole* string (default(...)'s own closing paren satisfies
    # ends_with(')') too, not just lookup(...)'s), swallowing the entire
    # filter chain into evaluate_lookup as one garbled, unbalanced
    # argument before top_level_pipe?/evaluate_with_filter ever got a
    # chance to split it properly. An unset env var with no matching
    # default(..., true) call previously stayed the literal string
    # "undefined" (non-empty, so default()'s own falsy check never fired
    # even once reached) instead of "" (real Ansible's own lookup('env',
    # ...) return for an unset var).
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST_2') | default('2.0.3', true))).should eq("2.0.3")
  end

  it "evaluates an else-less inline if as empty string when the condition is false" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version_release_site_suffix: "{{ '+ent' if vault_enterprise
    # }}{{ '.hsm' if vault_enterprise_hsm }}"` - real Jinja2 renders the
    # missing else branch as "" (Undefined's default __str__), but this
    # fell through to plain variable lookup on the literal text `'+ent' if
    # vault_enterprise`, always resolving to "undefined".
    v = Hash(String, JSON::Any).new
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('+ent' if vault_enterprise)).should eq("")

    v["vault_enterprise"] = JSON::Any.new(true)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('+ent' if vault_enterprise)).should eq("+ent")
  end

  it "resolves a ternary whose branches are bare boolean literals, not quoted strings" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_copy_keys: "{{ false if (vault_install_hashi_repo) else
    # true }}"` - the chosen branch's bare `true`/`false` text (as
    # opposed to a quoted string literal like '+ent') fell through to a
    # plain variable lookup on that literal identifier, always
    # "undefined" - which `| bool` downstream then treated as truthy
    # regardless of the actual condition.
    v = Hash(String, JSON::Any).new
    v["vault_install_hashi_repo"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("false if vault_install_hashi_repo else true").should eq("true")

    v["vault_install_hashi_repo"] = JSON::Any.new(true)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("false if vault_install_hashi_repo else true").should eq("false")
  end

  it "re-templates a filter chain's own head variable when its raw value is still unrendered Jinja" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_gossip: "{{ lookup('env', 'VAULT_TLS_GOSSIP') | default(
    # false, true) }}"` used later as `vault_tls_gossip | bool` - the
    # filter chain's own head-variable resolution (the plain-lookup
    # fallback in evaluate_with_filter) returned the raw, unrendered
    # template text unchanged, which is a non-empty string - so `| bool`
    # saw it as truthy regardless of what it actually rendered to.
    v = Hash(String, JSON::Any).new
    v["vault_tls_gossip"] = JSON::Any.new(%({{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST') | default(false, true) }}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_tls_gossip | bool").should eq("False")

    ENV["CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST"] = "true"
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_tls_gossip | bool").should eq("True")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST")
  end

  it "concatenates operands with Jinja2's `~` string-concat operator" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version~('+ent' if vault_enterprise)` (a bare-`~`
    # concatenation whose right operand is itself a parenthesized,
    # else-less ternary) - `~` was entirely unimplemented anywhere in the
    # engine, so the whole expression fell through to a plain (always-
    # undefined) variable lookup on the literal text.
    v = Hash(String, JSON::Any).new
    v["vault_version"] = JSON::Any.new("2.0.3")
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_version~('+ent' if vault_enterprise)").should eq("2.0.3")

    v["vault_enterprise"] = JSON::Any.new(true)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_version~('+ent' if vault_enterprise)").should eq("2.0.3+ent")
  end

  it "renders a bare numeric literal, alone or as a filter chain's own head" do
    # Real bug found in the same investigation as the */÷ arithmetic fix
    # below: a bare numeric literal was never checked anywhere in this
    # dispatch chain on its own (only ever as an *operand* inside a
    # `+`/`-`/`*`/`/` expression) - `{{ 5 }}` alone, or `{{ 5.7 | int
    # }}` (a literal float piped straight into a filter, no variable or
    # arithmetic involved), both fell through to a plain variable-name
    # lookup on the literal digit text itself, always "undefined".
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("5").should eq("5")
    evaluator.evaluate("5.7").should eq("5.7")
    evaluator.evaluate("5.7 | int").should eq("5")
    evaluator.evaluate("(5.7) | int").should eq("5")
  end

  it "evaluates *, /, and // arithmetic, matching real Jinja2/Python semantics exactly" do
    # Real bug found benchmarking geerlingguy.swap's own check-size.yml:
    # `(swap_file_check.stat.size / 1024 / 1024) | int` (converting a
    # stat'd byte count to MB) - `*`/`/`/`//` were entirely unimplemented
    # anywhere in the engine (only `+`/`-`/`~` had top-level operator
    # support), so even a bare `{{ 10 / 2 }}` rendered the literal
    # string "undefined". The whole file-size comparison this feeds
    # always differed, deleting and recreating the swap file on every
    # single run instead of converging. Values verified directly against
    # real Python's own jinja2.Environment: `/` always produces a float
    # (true division, even when evenly divisible), `*` preserves int
    # when both operands are int, `//` floors to int, and `*`/`/` bind
    # tighter than `+`/`-` (`2 + 3 * 4` == 14, not 20).
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new(268435456_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("10 / 2").should eq("5.0")
    evaluator.evaluate("10 / 3").should eq("3.3333333333333335")
    evaluator.evaluate("10 // 3").should eq("3")
    evaluator.evaluate("10 * 2").should eq("20")
    evaluator.evaluate("2.5 * 2").should eq("5.0")
    evaluator.evaluate("2 + 3 * 4").should eq("14")
    evaluator.evaluate("n / 1024 / 1024").should eq("256.0")
  end

  it "evaluates a full boolean expression (is test, or, comparison) inside a plain {{ }} span" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `installation_required: "{{ vault_installation is failed or
    # installed_vault_version.stdout != vault_version~(...) }}"` -
    # ConditionalEvaluator (used for bare when:/failed_when:/assert
    # conditions) already understood `is failed`/`or`/comparisons, but
    # this evaluator (used for {{ }} spans, e.g. set_fact: values) had no
    # concept of any of the three - `is failed` alone rendered
    # "undefined", and the whole `or` expression fell through to a plain
    # (always-undefined) variable lookup on the literal text, which
    # formatted as truthy "True" regardless of the real values.
    v = Hash(String, JSON::Any).new
    v["result"] = JSON.parse(%({"failed": false}))
    v["a"] = JSON::Any.new("x")
    v["b"] = JSON::Any.new("x")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("result is failed or a != b").should eq("False")

    v["b"] = JSON::Any.new("y")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("result is failed or a != b").should eq("True")
  end

  it "treats a plain-value `or`/`and` as a value-selector, not a boolean coercion" do
    # Real bug found benchmarking robertdebock.users: `groups: "{{
    # user.groups | default([]) | join(',') or omit }}"` - since neither
    # operand is a boolean condition (no comparison/is-test), real
    # Jinja2's `or` must return the joined string itself when truthy,
    # not the literal text "True". The fix above only added boolean
    # coercion for genuine conditions; a plain "X or Y" previously still
    # rendered "True"/"False" regardless of X/Y's actual values -
    # `useradd: group 'True' does not exist` was the resulting failure.
    v = Hash(String, JSON::Any).new
    v["groups"] = JSON.parse(%(["ops", "sudo"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("groups | join(',') or omit").should eq("ops,sudo")

    v["groups"] = JSON.parse(%([]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("groups | join(',') or omit").should eq(CrystalPlay::OMIT_SENTINEL)

    v2 = Hash(String, JSON::Any).new
    evaluator2 = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v2)
    evaluator2.evaluate("'ops,sudo' or 'fallback'").should eq("ops,sudo")
    evaluator2.evaluate("'' or 'fallback'").should eq("fallback")
    evaluator2.evaluate("5 or 'fallback'").should eq("5")
  end

  it "treats a plain-value `and` as a value-selector too" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'first' and 'second'").should eq("second")
    evaluator.evaluate("'' and 'second'").should eq("")
  end

  it "compares a dotted operand against a `~`-concatenated one, full ansible-vault expression" do
    # End-to-end regression for the exact expression benchmarked from
    # ansible-community.ansible-vault's own "Compute if installation is
    # required" task: `installed_vault_version.stdout != vault_version~
    # ('+ent' if vault_enterprise)`. Comparison operators must be
    # detected (has_comparison?) before the `~` split ever runs, or the
    # whole thing gets sliced on `~` first instead of `!=` - covering the
    # dispatch-order interaction directly, on top of the narrower
    # ComparisonEvaluator-only and ExpressionEvaluator-only specs above.
    v = Hash(String, JSON::Any).new
    v["installed_vault_version"] = JSON.parse(%({"stdout": "2.0.3"}))
    v["vault_version"] = JSON::Any.new("2.0.3")
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("installed_vault_version.stdout != vault_version~('+ent' if vault_enterprise)").should eq("false")
  end

  it "evaluates a bare quoted string literal with no filter/operator at all" do
    # Real bug found benchmarking cloudalchemy.prometheus: a bare
    # literal containing a `.` (routine for a URL or IP address -
    # `lookup('url', '...' + version + '...')`'s own URL argument, once
    # split out and re-evaluated as its own operand) fell through to
    # the `expr.includes?(".")` dotted-lookup branch, which treated the
    # literal text - quotes included - as a dotted variable PATH rather
    # than a plain string value, always undefined. No prior spec covered
    # a bare `{{ '...' }}` span with no `|`/ternary/operator at all.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('http://127.0.0.1:8080/some.file.txt')).should eq("http://127.0.0.1:8080/some.file.txt")
  end

  it "does not mistake a `+` chain starting and ending in quotes for one bare literal" do
    # Real regression introduced fixing the bug above: the bare-literal
    # check used #quoted_string_literal (first/last char only), which
    # also matches `'a' + var + 'b'` - both ends are quotes too, just not
    # the SAME literal. Caught immediately via cloudalchemy.prometheus's
    # own `lookup('url', 'https://...v' + prometheus_version + '/...',
    # wantlist=True)` - the URL argument gets re-evaluated as its own
    # bare operand, and the naive check stripped only the outer quotes,
    # leaving " + prometheus_version + " as literal garbage text in the
    # middle of the "URL".
    v = Hash(String, JSON::Any).new
    v["prometheus_version"] = JSON::Any.new("2.27.0")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('https://example.com/v' + prometheus_version + '/sums.txt')).should eq("https://example.com/v2.27.0/sums.txt")
  end
end

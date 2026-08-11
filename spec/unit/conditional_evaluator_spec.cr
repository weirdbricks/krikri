require "../spec_helper"
require "../../src/crystal_play/conditional_evaluator"

private def vars(hash : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  hash.each { |k, v| result[k] = JSON::Any.new(v) }
  result
end

private EMPTY_VARS = Hash(String, JSON::Any).new

describe CrystalPlay::ConditionalEvaluator do
  describe "equality" do
    it "evaluates == true when values match" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_true
    end

    it "evaluates == false when values differ" do
      v = vars({"foo" => "baz"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_false
    end

    it "evaluates !=" do
      v = vars({"foo" => "baz"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo != "bar"), v).should be_true
    end
  end

  describe "numeric comparisons" do
    it "evaluates <" do
      v = vars({"count" => 3_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count < 5", v).should be_true
    end

    it "evaluates >" do
      v = vars({"count" => 3_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count > 5", v).should be_false
    end

    it "evaluates <=" do
      v = vars({"count" => 5_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count <= 5", v).should be_true
    end

    it "evaluates >=" do
      v = vars({"count" => 5_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count >= 6", v).should be_false
    end
  end

  describe "boolean operators" do
    it "evaluates 'and' requiring all parts true" do
      v = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("a and b", v).should be_false
    end

    it "evaluates 'or' requiring any part true" do
      v = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("a or b", v).should be_true
    end

    it "evaluates leading 'not'" do
      v = vars({"a" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("not a", v).should be_true
    end
  end

  describe "membership ('in')" do
    it "checks substring membership" do
      CrystalPlay::ConditionalEvaluator.evaluate(%("ba" in "bar"), EMPTY_VARS).should be_true
    end

    it "checks 'not in' membership (os_hardening's su-binary gate)" do
      v = Hash(String, JSON::Any).new
      v["os_security_users_allow"] = JSON::Any.new(Array(JSON::Any).new)
      CrystalPlay::ConditionalEvaluator.evaluate(%('change_user' not in os_security_users_allow), v).should be_true
    end

    it "'not in' is false when the list does contain the item" do
      v = Hash(String, JSON::Any).new
      v["os_security_users_allow"] = JSON::Any.new([JSON::Any.new("change_user")])
      CrystalPlay::ConditionalEvaluator.evaluate(%('change_user' not in os_security_users_allow), v).should be_false
    end

    it "checks membership in a literal numeric list against a real int item" do
      # Real bug found benchmarking openstack.ansible-hardening's own
      # kdump-service check: `failed_when: result.rc not in [0, 3, 4]`.
      # Every array value this evaluator produces (literal or variable)
      # stringifies its elements, but the compared item (a registered
      # command's `.rc`) keeps its real Int64 type - comparing an Int64
      # against String array elements unstringified always came back
      # false, so `rc not in [...]` always evaluated true regardless of
      # the real rc, hard-failing a task real Ansible treats as success.
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"rc": 4}))
      CrystalPlay::ConditionalEvaluator.evaluate("result.rc in [0, 3, 4]", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("result.rc not in [0, 3, 4]", v).should be_false

      v["result"] = JSON.parse(%({"rc": 7}))
      CrystalPlay::ConditionalEvaluator.evaluate("result.rc in [0, 3, 4]", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("result.rc not in [0, 3, 4]", v).should be_true
    end
  end

  describe "out-of-line parentheses from list-when ANDing" do
    it "unwraps a fully parenthesized clause (each clause of a list-when)" do
      v = Hash(String, JSON::Any).new
      v["ansible_facts"] = JSON::Any.new({"os_family" => JSON::Any.new("Debian")})
      combined = %((ansible_facts.os_family != 'Suse') and (ansible_facts.os_family != 'Archlinux'))
      CrystalPlay::ConditionalEvaluator.evaluate(combined, v).should be_true
    end

    it "does not unwrap a paren that is not a full wrap (trailing content)" do
      v = vars({"a" => "x"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%((a == "x") and true), v).should be_true
    end
  end

  describe "definedness" do
    it "evaluates 'is defined' true for present variables" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("foo is defined", v).should be_true
    end

    it "evaluates 'is not defined' true for missing variables" do
      CrystalPlay::ConditionalEvaluator.evaluate("foo is not defined", EMPTY_VARS).should be_true
    end
  end

  describe "registered task result tests (is failed/succeeded/success/changed/skipped)" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `when: not vault_installation is failed` (gating "Get installed
    # Vault version" on the previous task's own success) - entirely
    # unimplemented before, fell through to #evaluate_truthiness (no
    # notion of `is` tests at all), always evaluating the whole "X is
    # failed" text as an undefined variable lookup - always falsy,
    # so `not ... is failed` was always true regardless of the real
    # result, running the version-check command even on a completely
    # fresh host where the previous task had genuinely failed.
    it "reads 'failed' off a registered result" do
      v = Hash(String, JSON::Any).new
      v["check"] = JSON.parse(%({"failed": true, "changed": false}))
      CrystalPlay::ConditionalEvaluator.evaluate("check is failed", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("not check is failed", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("check is not failed", v).should be_false
    end

    it "'succeeded'/'success' are the inverse of 'failed', not a separate stored field" do
      v = Hash(String, JSON::Any).new
      v["check"] = JSON.parse(%({"failed": false, "changed": true}))
      CrystalPlay::ConditionalEvaluator.evaluate("check is succeeded", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("check is success", v).should be_true

      v["check"] = JSON.parse(%({"failed": true}))
      CrystalPlay::ConditionalEvaluator.evaluate("check is succeeded", v).should be_false
    end

    it "reads 'changed'/'skipped' off a registered result" do
      v = Hash(String, JSON::Any).new
      v["check"] = JSON.parse(%({"failed": false, "changed": true}))
      CrystalPlay::ConditionalEvaluator.evaluate("check is changed", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("check is not skipped", v).should be_true
    end
  end

  describe "truthiness" do
    it "treats a bare true variable as truthy" do
      v = vars({"flag" => true} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("flag", v).should be_true
    end

    it "treats a bare false variable as falsy" do
      v = vars({"flag" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("flag", v).should be_false
    end

    it "treats an undefined bare variable as falsy" do
      CrystalPlay::ConditionalEvaluator.evaluate("missing", EMPTY_VARS).should be_false
    end

    it "treats a non-empty string as truthy" do
      v = vars({"name" => "x"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("name", v).should be_true
    end

    it "treats an empty string as falsy" do
      v = vars({"name" => ""} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("name", v).should be_false
    end
  end

  describe "dotted variable access" do
    # Regression tests for a real, previously-shipped gap: this bare
    # (non-{{ }}) evaluator only ever did a plain vars.has_key?(expr)
    # lookup, so a when:/until:/changed_when:/failed_when: referencing a
    # dotted result field (the ordinary, unwrapped way real Ansible
    # expects when: to be written) silently evaluated to undefined
    # instead of the real value.
    it "resolves a single-level dotted field for equality" do
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"rc": 0}))
      CrystalPlay::ConditionalEvaluator.evaluate("result.rc == 0", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("result.rc != 0", v).should be_false
    end

    it "resolves a two-level (nested) dotted field for truthiness" do
      v = Hash(String, JSON::Any).new
      v["stat_result"] = JSON.parse(%({"stat": {"exists": true}}))
      CrystalPlay::ConditionalEvaluator.evaluate("stat_result.stat.exists", v).should be_true
    end

    it "treats a dotted field resolving to false as falsy" do
      v = Hash(String, JSON::Any).new
      v["stat_result"] = JSON.parse(%({"stat": {"exists": false}}))
      CrystalPlay::ConditionalEvaluator.evaluate("stat_result.stat.exists", v).should be_false
    end

    it "treats a missing dotted field as undefined (falsy), not an error" do
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"rc": 0}))
      CrystalPlay::ConditionalEvaluator.evaluate("result.nonexistent", v).should be_false
    end

    it "does not treat a float literal's decimal point as a dotted variable path" do
      # A float literal like "1.5" also contains a "." - without the
      # to_f64? guard, evaluate_value would split it into ["1", "5"] and,
      # if a variable literally named "1" happened to exist, resolve it as
      # a dotted lookup ("look up variable 1, then its nested field 5")
      # instead of treating "1.5" as the numeric literal it is.
      v = Hash(String, JSON::Any).new
      v["1"] = JSON.parse(%({"5": "unexpected"}))
      CrystalPlay::ConditionalEvaluator.evaluate(%(1.5 == "unexpected"), v).should be_false
    end

    it "still evaluates a plain (non-dotted) variable normally" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_true
    end
  end

  describe "filter chains" do
    # Real, previously-shipped bug: this module had no concept of `|` at
    # all, so any condition combining a filter with a comparison (or used
    # bare) evaluated the filter-chain text itself as an undefined
    # variable name - `mylist | length > 0` always evaluated false,
    # regardless of the actual list (see git log's 0.9.58 commit).

    it "evaluates a filter chain combined with a comparison (the originally-reported case)" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
      CrystalPlay::ConditionalEvaluator.evaluate("mylist | length > 0", v).should be_true
    end

    it "evaluates false when the filtered value doesn't satisfy the comparison" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([] of JSON::Any)
      CrystalPlay::ConditionalEvaluator.evaluate("mylist | length > 0", v).should be_false
    end

    it "evaluates a bare filter chain for truthiness (no comparison at all)" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b")])
      CrystalPlay::ConditionalEvaluator.evaluate("mylist | length", v).should be_true

      v["mylist"] = JSON::Any.new([] of JSON::Any)
      CrystalPlay::ConditionalEvaluator.evaluate("mylist | length", v).should be_false
    end

    it "evaluates a filter chain on a dotted (nested) operand" do
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"stdout": "  hello  "}))
      CrystalPlay::ConditionalEvaluator.evaluate(%(result.stdout | trim == "hello"), v).should be_true
    end

    it "evaluates a chained (multi-filter) pipeline as a comparison operand" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("b"), JSON::Any.new("a")])
      CrystalPlay::ConditionalEvaluator.evaluate(%(mylist | sort | join(',') == "a,b"), v).should be_true
    end

    it "combines a filter-chain comparison with and/or without regressing existing operators" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
      CrystalPlay::ConditionalEvaluator.evaluate("mylist | length > 0 and mylist | length == 3", v).should be_true
    end

    it "re-templates a bare variable whose own raw value is still unrendered Jinja before checking truthiness" do
      # Real bug found benchmarking ansible-community.ansible-vault:
      # `vault_enterprise: "{{ lookup('env', 'VAULT_ENTERPRISE') |
      # default(false, true) }}"` used as a bare ternary condition
      # (`'+ent' if vault_enterprise`) elsewhere in the role's own
      # defaults/main.yml. Previously the raw, unrendered template text
      # was treated as a truthy non-empty string regardless of what it
      # actually rendered to.
      v = Hash(String, JSON::Any).new
      v["vault_enterprise"] = JSON::Any.new(%({{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_COND_ENV_TEST') | default(false, true) }}))
      CrystalPlay::ConditionalEvaluator.evaluate("vault_enterprise", v).should be_false

      ENV["CRYSTAL_ANSIBLE_SPEC_COND_ENV_TEST"] = "true"
      CrystalPlay::ConditionalEvaluator.evaluate("vault_enterprise", v).should be_true
      ENV.delete("CRYSTAL_ANSIBLE_SPEC_COND_ENV_TEST")
    end

    it "re-templates a bare variable used as a `+`-operand inside an `in` check" do
      # Real bug found benchmarking cloudalchemy.prometheus's own
      # `go_arch: "{{ go_arch_map[ansible_architecture] | default(
      # ansible_architecture) }}"` (role vars/main.yml, not defaults/)
      # used as `('linux-' + go_arch + '.tar.gz') in item` - the fifth
      # (and so far last) independent plain-lookup fallback needing this
      # exact fix. `{{ go_arch }}` alone rendered correctly elsewhere (a
      # different, already-fixed code path), but resolve_plus_operand's
      # own plain-lookup fallback for a bare `+`-operand returned the
      # raw, unrendered template text, so the `in` check against every
      # real checksum-file line always came back false.
      v = Hash(String, JSON::Any).new
      v["go_arch"] = JSON::Any.new(%({{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_COND_ENV_TEST_2') | default('amd64', true) }}))
      v["item"] = JSON::Any.new("prometheus-2.27.0.linux-amd64.tar.gz")
      CrystalPlay::ConditionalEvaluator.evaluate(%(('linux-' + go_arch + '.tar.gz') in item), v).should be_true
    end

    it "evaluates 'is mapping' / 'is sequence' (plus negations), real Jinja2 type tests" do
      # Real bug found benchmarking cloudalchemy.grafana's own defaults-
      # sanity assert: `grafana_security is mapping`. Entirely
      # unimplemented before - fell through to #evaluate_truthiness,
      # which has no notion of `is` tests at all and treated the whole
      # "X is mapping" text as an undefined variable lookup, always
      # false - failing the assert regardless of the variable's real
      # type.
      v = Hash(String, JSON::Any).new
      v["a_dict"] = JSON.parse(%({"http_port": 3000}))
      v["a_list"] = JSON.parse(%([1, 2, 3]))
      v["a_string"] = JSON::Any.new("hello")

      CrystalPlay::ConditionalEvaluator.evaluate("a_dict is mapping", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_list is mapping", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("a_list is sequence", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_dict is not sequence", v).should be_true
      # A bare String deliberately does NOT match `is sequence` - every
      # real playbook using this pattern means "is this a list", and
      # matching String too (technically valid Python/Jinja2 semantics,
      # since strings are iterable) would make `is not sequence` wrongly
      # reject ordinary string variables.
      CrystalPlay::ConditionalEvaluator.evaluate("a_string is not sequence", v).should be_true
    end

    it "evaluates 'is match(...)' / 'is search(...)' (plus negations), real Jinja2 regex tests" do
      # Real bug found benchmarking geerlingguy.node_exporter's own
      # `when: node_exporter_version is match("latest") or
      # node_exporter_version is not defined` (deciding whether to
      # resolve "latest" to a real GitHub release tag). Entirely
      # unimplemented before - fell through to #evaluate_truthiness,
      # always false - so node_exporter_version stayed the literal
      # string "latest", building a download URL for a release that
      # doesn't exist and failing the download outright.
      v = Hash(String, JSON::Any).new
      v["version"] = JSON::Any.new("latest")
      v["path"] = JSON::Any.new("v1.8.2-rc1")

      # match() anchors at the START only (Python's re.match, not a
      # full-string anchor) - "latest" itself, and any string merely
      # *starting* with "latest", both match.
      CrystalPlay::ConditionalEvaluator.evaluate(%(version is match("latest")), v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate(%(version is not match("late")), v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate(%(version is match("^lat")), v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate(%(version is match("stable")), v).should be_false

      # search() matches anywhere in the string (Python's re.search).
      CrystalPlay::ConditionalEvaluator.evaluate(%(path is search("\\d+\\.\\d+\\.\\d+")), v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate(%(path is not search("nomatch")), v).should be_true
    end

    it "resolves 'is (not) defined' against a dotted variable path" do
      # Real bug found benchmarking cloudalchemy.grafana's own "Fail
      # when grafana admin user isn't set" task: `grafana_security.
      # admin_user is not defined`. `vars.has_key?(var_name)` (the
      # previous implementation) always returns false for a dotted
      # path, since no literal key containing a "." exists in `vars` -
      # this always evaluated true regardless of whether admin_user was
      # actually set, unconditionally failing the role's own preflight
      # check on every run.
      v = Hash(String, JSON::Any).new
      v["grafana_security"] = JSON.parse(%({"admin_user": "admin"}))

      CrystalPlay::ConditionalEvaluator.evaluate("grafana_security.admin_user is defined", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("grafana_security.admin_user is not defined", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("grafana_security.admin_password is not defined", v).should be_true
    end

    it "audit pass: re-templates before checking 'is mapping'/'is sequence'" do
      # Proactive audit (2026-08-11), not found via a real-host round:
      # after finding 5 independent copies of the recursive-re-
      # templating bug across rounds 2-3, grepped every remaining
      # VariableLookup#resolve call site in the engine for the same
      # missing guard. matches_type_test? (is mapping/sequence) was one
      # of them - a variable whose own raw value is itself unrendered
      # Jinja (a role default computed from another default) resolved
      # to a String here, always failing the test regardless of what it
      # actually renders to.
      v = Hash(String, JSON::Any).new
      v["templated_dict"] = JSON::Any.new("{{ real_dict }}")
      v["real_dict"] = JSON.parse(%({"a": 1}))
      CrystalPlay::ConditionalEvaluator.evaluate("templated_dict is mapping", v).should be_true
    end

    it "audit pass: re-templates a dotted lookup's own unrendered value" do
      # Same audit as above - #evaluate_value's dotted-access branch and
      # #resolve_json (used by the `in` operator's left-hand side and
      # filter-chain heads on a dotted path) both lacked the re-render
      # guard the BARE-identifier "Variable lookup" case right below
      # them already had.
      v = Hash(String, JSON::Any).new
      v["outer"] = JSON.parse(%({"inner": "{{ real_val }}"}))
      v["real_val"] = JSON::Any.new("resolved")
      CrystalPlay::ConditionalEvaluator.evaluate("outer.inner == 'resolved'", v).should be_true
    end
  end
end

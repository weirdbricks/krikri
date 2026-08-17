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

  describe "arithmetic operators in a bare when:/assert: value" do
    it "evaluates */÷ in a comparison operand, not just inside {{ }} interpolation" do
      # Real bug found benchmarking geerlingguy.swap's own check-size.yml
      # doing its own `stat.size / 1024 / 1024` comparison as a bare
      # when:/assert:-style value: #evaluate_value's own guard for "does
      # this need the full ExpressionEvaluator" checked for `|`, leading
      # `(`, ` - `, and `~`, but not `*`/`/` - even after
      # ExpressionEvaluator itself gained arithmetic support (for `{{ }}`
      # interpolation), a bare `when: n / 2 == 5` still fell through to
      # this module's own much simpler dispatch, which has no arithmetic
      # concept at all, and always evaluated false.
      v = vars({"n" => 10_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("n / 2 == 5", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("n / 2 == 6", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("n * 2 == 20", v).should be_true
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

    it "short-circuits 'not a or b' as (not a) or b, not not(a or b)" do
      # Real bug found benchmarking geerlingguy.helm: "Download helm."
      # gates on `when: not helm_check.stat.exists or "{{ helm_version
      # }}" not in helm_existing_version.stdout`. With the binary not
      # yet installed, `not helm_check.stat.exists` alone is already
      # true, and real Ansible's `or` short-circuits there without ever
      # evaluating the second clause (whose own `.stdout` is undefined
      # after a failed_when:false command spawn failure - erroring if
      # actually evaluated). `evaluate` used to check a leading "not "
      # prefix BEFORE splitting on " or "/" and " at all, so it negated
      # the ENTIRE remaining "a or b" as one unit (`not (a or b)`)
      # instead of correctly binding only to the immediate next term -
      # discarding short-circuiting and returning the wrong (and, for
      # the real playbook, erroring-clause-dependent) result.
      v = vars({"a" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(not a or "x" in undefined_var.stdout), v).should be_true
    end
  end

  describe "bare-variable truthiness" do
    it "treats an empty list/dict as falsy, matching real Python's bool([])/bool({})" do
      # Real bug found in an audit pass following the Crinja Value#
      # truthy? fix (same bug class - empty-container truthiness - in a
      # completely separate, hand-rolled evaluator this codebase also
      # maintains): #evaluate_value's own return union (String | Int64 |
      # Bool | Nil | Array(String)) has no Hash case at all (an empty
      # Hash's own #to_s, "{}", is a non-empty STRING - always truthy)
      # and every Array collapsed to Array(String) with no truthiness
      # case in #evaluate_truthiness's own `case` either (silently
      # falling through to an unconditional `else -> true`). `when:
      # my_list` with `my_list: []` (or `my_dict: {}`) always ran the
      # task.
      v = Hash(String, JSON::Any).new
      v["my_list"] = JSON.parse("[]")
      v["my_dict"] = JSON.parse("{}")
      CrystalPlay::ConditionalEvaluator.evaluate("my_list", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("my_dict", v).should be_false
    end

    it "treats a non-empty list/dict as truthy" do
      v = Hash(String, JSON::Any).new
      v["my_list"] = JSON.parse(%(["a"]))
      v["my_dict"] = JSON.parse(%({"k": "v"}))
      CrystalPlay::ConditionalEvaluator.evaluate("my_list", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("my_dict", v).should be_true
    end

    it "treats an empty list reached via a dotted path as falsy too" do
      v = Hash(String, JSON::Any).new
      v["nested"] = JSON.parse(%({"empty_list": []}))
      CrystalPlay::ConditionalEvaluator.evaluate("nested.empty_list", v).should be_false
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

    it "handles a quoted literal that itself contains the word 'in' as its own word" do
      # Real bug found benchmarking a real geerlingguy.glusterfs 3-node
      # cluster: a hand-written peer-probe task's own idempotency check
      # is `changed_when: "'already in peer list' not in probe2.stdout"`
      # (gluster peer probe prints exactly that phrase for an already-
      # probed peer). evaluate_in's own naive `condition.split(" in ",
      # 2)` isn't quote-aware, so it split at the FIRST " in " it found
      # - the one INSIDE the quoted literal ("already[ in ]peer list") -
      # instead of the real `in` operator further along, producing a
      # nonsensical item/container pair and evaluating changed_when as
      # true on every single run regardless of the actual stdout,
      # breaking idempotency outright for a real multi-node cluster
      # playbook.
      v = Hash(String, JSON::Any).new
      v["probe2"] = JSON.parse(%({"stdout": "already in peer list"}))
      CrystalPlay::ConditionalEvaluator.evaluate(%('already in peer list' not in probe2.stdout), v).should be_false
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

    it "checks membership against a METHOD CALL (not just a bare variable or filter)" do
      # Real bug found benchmarking robertdebock.squid (round 48,
      # crystal-ansible 0.9.389): its own assert.yml has
      # `squid_cache_dir.split(" ")[0] in [ "ufs", "aufs", ... ]` - a
      # Python-style `.split(...)` METHOD call (not a `| split` Jinja
      # filter) followed by indexing. #evaluate_value's
      # ExpressionEvaluator-routing guard only checked for `|`, a
      # leading `(`, ` - `, `~`, `*`, `/` - none of which this
      # expression contains - so it fell through to the naive
      # dotted/indexed-access splitter instead, which has no concept of
      # a parenthesized method call at all and just failed to resolve
      # it (always undefined). `{{ squid_cache_dir.split(" ")[0] }}`
      # alone already rendered correctly (goes through the full
      # ExpressionEvaluator via the {{ }} path) - only the bare,
      # unwrapped `assert: that:`/`when:` condition form was broken.
      v = Hash(String, JSON::Any).new
      v["squid_cache_dir"] = JSON::Any.new("aufs /var/spool/squid 16000 16 256 max-size=8589934592")

      CrystalPlay::ConditionalEvaluator.evaluate(
        %(squid_cache_dir.split(" ")[0] in [ "ufs", "aufs", "diskd", "rock", "null" ]), v
      ).should be_true

      v["squid_cache_dir"] = JSON::Any.new("bogus /var/spool/squid")
      CrystalPlay::ConditionalEvaluator.evaluate(
        %(squid_cache_dir.split(" ")[0] in [ "ufs", "aufs", "diskd", "rock", "null" ]), v
      ).should be_false
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

    it "evaluates 'is boolean' / 'is number' / 'is string' / 'is integer' / 'is float' / 'is iterable', the rest of Jinja2's own type tests" do
      # Real bug found benchmarking robertdebock.bootstrap's own defaults-
      # sanity assert: `bootstrap_wait_for_host is defined and
      # bootstrap_wait_for_host is boolean`. Entirely unimplemented before,
      # same failure mode 'is mapping'/'is sequence' originally had -
      # fell through to #evaluate_truthiness, always false, failing the
      # assert on a real, correctly-typed default (`false`).
      v = Hash(String, JSON::Any).new
      v["a_bool"] = JSON::Any.new(false)
      v["an_int"] = JSON::Any.new(3_i64)
      v["a_float"] = JSON::Any.new(3.5)
      v["a_string"] = JSON::Any.new("hello")
      v["a_list"] = JSON.parse(%([1, 2, 3]))

      CrystalPlay::ConditionalEvaluator.evaluate("a_bool is boolean", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("an_int is boolean", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("an_int is number", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_float is number", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("an_int is integer", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_float is integer", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("a_float is float", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_string is string", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("an_int is string", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("a_list is iterable", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_string is iterable", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("an_int is not iterable", v).should be_true
    end

    it "evaluates a type test against a FILTER CHAIN, not just a bare variable" do
      # Real bug found benchmarking robertdebock.java (round 45,
      # crystal-ansible 0.9.388): its own assert.yml has `java_version |
      # int is number` and `java_version | int in [6, 7, ...]` -
      # #matches_type_test?'s var_name-lookup treated the WHOLE
      # "java_version | int" string (filter pipe included) as a literal
      # variable name, doing a bare `vars["java_version | int"]?` hash
      # lookup that obviously never matches any real key - always
      # undefined, always failing the type test regardless of what
      # java_version | int actually evaluates to. Confirmed on a real
      # host: a `{{ java_version | int is number }}` debug interpolation
      # of the exact same text correctly printed "True" (goes through
      # the full expression evaluator), while the identical text inside
      # an assert:'s `that:` list still failed (goes through
      # ConditionalEvaluator directly instead).
      v = Hash(String, JSON::Any).new
      v["java_version"] = JSON::Any.new("19")

      CrystalPlay::ConditionalEvaluator.evaluate("java_version | int is number", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("java_version | int in [6, 7, 8, 9, 10, 11, 12, 13, 17, 19, 20, 21]", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("java_version | int in [6, 7, 8]", v).should be_false
    end

    it "evaluates 'is none', real Jinja2's None/null test" do
      # Real bug found benchmarking robertdebock.mysql's own defaults-
      # sanity assert: `mysql_bind_address is defined and
      # mysql_bind_address is string and mysql_bind_address is not none`
      # (round 18). Entirely unimplemented before - fell through to
      # #evaluate_truthiness, always false, so `is not none` failed the
      # assert even for a real, correctly-set string default.
      v = Hash(String, JSON::Any).new
      v["a_string"] = JSON::Any.new("127.0.0.1")
      v["a_null"] = JSON::Any.new(nil)

      CrystalPlay::ConditionalEvaluator.evaluate("a_string is none", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("a_string is not none", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a_null is none", v).should be_true
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

    it "evaluates 'is subset(...)' / 'is superset(...)' / 'is contains(...)' (plus negations)" do
      v = Hash(String, JSON::Any).new
      v["small"] = JSON.parse(%(["a", "b"]))
      v["big"] = JSON.parse(%(["a", "b", "c"]))
      v["items"] = JSON.parse(%(["x", "y", "z"]))

      CrystalPlay::ConditionalEvaluator.evaluate("small is subset(big)", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("big is subset(small)", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("big is superset(small)", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("small is not superset(big)", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate(%(items is contains("y")), v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate(%(items is not contains("q")), v).should be_true
    end

    it "evaluates 'is exists' / 'is file' / 'is directory' / 'is link' / 'is link_exists' against the CONTROLLER's filesystem" do
      file_path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "conditional_path_test.txt")
      dir_path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "conditional_path_test_dir")
      link_path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "conditional_path_test_link")
      File.write(file_path, "content")
      Dir.mkdir_p(dir_path)
      File.delete(link_path) if File.exists?(link_path) || File.symlink?(link_path)
      File.symlink(file_path, link_path)

      v = Hash(String, JSON::Any).new
      v["f"] = JSON::Any.new(file_path)
      v["d"] = JSON::Any.new(dir_path)
      v["l"] = JSON::Any.new(link_path)
      v["missing"] = JSON::Any.new("/no/such/path/at/all")

      CrystalPlay::ConditionalEvaluator.evaluate("f is exists", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("f is file", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("f is not directory", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("d is directory", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("l is link", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("missing is not exists", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("l is link_exists", v).should be_true

      File.delete(link_path)
      File.delete(file_path)
      Dir.delete(dir_path)
    end

    it "evaluates 'is same_file(...)'" do
      path1 = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "same_file_a.txt")
      path2 = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "same_file_b.txt")
      File.write(path1, "same")
      File.write(path2, "different")

      v = Hash(String, JSON::Any).new
      v["a"] = JSON::Any.new(path1)
      v["b"] = JSON::Any.new(path1)
      v["c"] = JSON::Any.new(path2)

      CrystalPlay::ConditionalEvaluator.evaluate("a is same_file(b)", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("a is not same_file(c)", v).should be_true

      File.delete(path1)
      File.delete(path2)
    end

    it "falls back to Crinja for any real Jinja2 'is [not] <test>' this module hasn't hand-implemented (divisibleby, etc)" do
      # Real bug found benchmarking robertdebock.nomad's own assert:
      # `nomad_server_bootstrap_expect is not divisibleby 2` (verifying
      # an odd bootstrap_expect count). `divisibleby` (like most of
      # Jinja2's other built-in tests - even, odd, equalto, sameas,
      # escaped, callable...) had no special case anywhere in this
      # module, so the whole condition string fell straight through to
      # #evaluate_truthiness, which has no notion of `is` tests at all -
      # looked up as if "n is not divisibleby 2" were itself a literal
      # variable NAME, always undefined -> nil -> false, regardless of
      # the real divisibility (both an even and an odd operand evaluated
      # identically to false, not just "usually wrong").
      v = Hash(String, JSON::Any).new
      v["odd_n"] = JSON::Any.new(1_i64)
      v["even_n"] = JSON::Any.new(2_i64)

      CrystalPlay::ConditionalEvaluator.evaluate("odd_n is not divisibleby 2", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("even_n is not divisibleby 2", v).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("even_n is divisibleby 2", v).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("odd_n is divisibleby 2", v).should be_false
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

    it "treats the \"undefined\" sentinel string as falsy in a bare filter-chain condition" do
      # Real bug found benchmarking robertdebock.mount: `when:
      # mount_requests | regex_search("swap")` (the "Run swapon" handler's
      # own guard) - regex_search's own documented "no match" return is
      # the literal string "undefined" (this codebase's general
      # unresolved-lookup sentinel, not Python's None, but meant to behave
      # the same way in a boolean context). #evaluate_truthiness's String
      # case only special-cased "false"/"False" as falsy - a non-empty,
      # not-literally-"false" string is truthy by the general rule, so a
      # regex_search with no match still fired the handler unconditionally
      # regardless of whether the searched value actually matched.
      v = Hash(String, JSON::Any).new
      v["mount_requests"] = JSON.parse(%([{"path": "/mnt/tmp", "src": "/tmp", "opts": "bind", "fstype": "none"}]))
      CrystalPlay::ConditionalEvaluator.evaluate(%(mount_requests | regex_search("swap")), v).should be_false

      v["mount_requests"] = JSON.parse(%([{"path": "swap", "fstype": "swap"}]))
      CrystalPlay::ConditionalEvaluator.evaluate(%(mount_requests | regex_search("swap")), v).should be_true
    end

    it "compares a dotted-access value piped through | int at Int64 (byte-count) scale correctly" do
      # Real bug found benchmarking robertdebock.diskspace: `item.size_
      # available | int >= kilobytes_available | int` (the role's own
      # disk-space assertion). Two independent Int32-narrowing bugs
      # chained together to always evaluate false regardless of real
      # available space:
      #  1. VariableLookup#format_value's Int64/Int32 case used
      #     `JSON::Any#as_i` (always narrows to Int32), raising
      #     OverflowError for any real byte-scale Int64 - caught
      #     somewhere upstream and surfacing as a wrong (not crashed)
      #     result.
      #  2. The vendored Crinja fork's own `int` filter used `String#
      #     to_i?`/`Int#to_i` (also Int32-narrowing) - a real Int64-scale
      #     numeric STRING (`ansible_facts['mounts'][n].size_available`,
      #     which this codebase's own facts plugin stores as a string)
      #     silently returned the filter's own `default` (0) instead of
      #     the real number, no exception at all.
      # `46429401088` (≈46GB in bytes - a completely normal `size_
      # available` value on any real host) is comfortably past
      # Int32::MAX (~2.1 billion) and triggers both.
      v = Hash(String, JSON::Any).new
      v["item"] = JSON.parse(%({"size_available": "46429401088"}))
      v["kilobytes_available"] = JSON::Any.new("65536")
      CrystalPlay::ConditionalEvaluator.evaluate(
        "item.size_available | int >= kilobytes_available | int", v
      ).should be_true
    end
  end
end

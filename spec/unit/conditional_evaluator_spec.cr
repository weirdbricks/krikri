require "../spec_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/jinja_filters"

private def vars(hash : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  hash.each { |k, v| result[k] = JSON::Any.new(v) }
  result
end

private EMPTY_VARS = Hash(String, JSON::Any).new

describe Krikri::ConditionalEvaluator do
  describe "equality" do
    it "evaluates == true when values match" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_true
    end

    it "evaluates == false when values differ" do
      v = vars({"foo" => "baz"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_false
    end

    it "evaluates !=" do
      v = vars({"foo" => "baz"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(%(foo != "bar"), v).should be_true
    end
  end

  describe "numeric comparisons" do
    it "evaluates <" do
      v = vars({"count" => 3_i64} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("count < 5", v).should be_true
    end

    it "evaluates >" do
      v = vars({"count" => 3_i64} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("count > 5", v).should be_false
    end

    it "evaluates <=" do
      v = vars({"count" => 5_i64} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("count <= 5", v).should be_true
    end

    it "evaluates >=" do
      v = vars({"count" => 5_i64} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("count >= 6", v).should be_false
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
      Krikri::ConditionalEvaluator.evaluate("n / 2 == 5", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("n / 2 == 6", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("n * 2 == 20", v).should be_true
    end
  end

  describe "boolean operators" do
    it "evaluates 'and' requiring all parts true" do
      v = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("a and b", v).should be_false
    end

    it "evaluates 'or' requiring any part true" do
      v = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("a or b", v).should be_true
    end

    it "fully unwraps a double-wrapped parenthesized 'and'-joined clause" do
      # condition_to_string wraps each when:-list item in its own
      # "(#{clause})" before AND-joining the list. When the item is
      # ITSELF already parenthesized in the source YAML (a common shape
      # for a multi-line `- ( (a) or (b) )` when:-list item), the joined
      # AND-operand arrives double-wrapped: "((a) or (b))". A single
      # unwrap_outer_parens call only strips one layer, leaving a
      # residual "(a) or (b)" whose `or` sits at paren depth 1, not the
      # depth-0 the top-level or/and splitter looks for - so the whole
      # residual fell through to the truthy-string fallback (any
      # non-empty string reads true) instead of being evaluated as a
      # boolean expression. Found via bodsch.dnsmasq's own "ensure
      # dnsmasq.service.d is present" block: a 4-item when: list whose
      # last item is exactly this shape, with the referenced lists all
      # empty - real ansible-core 2.19.4 skips the block, crystal ran it.
      v = Hash(String, JSON::Any).new
      v["d"] = JSON.parse(%q({"unit": {"after": [], "wants": [], "requires": []}}))
      cond = "(d.unit | count > 0) and ((d.unit.after is defined and d.unit.after | count > 0) or " \
             "(d.unit.wants is defined and d.unit.wants | count > 0) or " \
             "(d.unit.requires is defined and d.unit.requires | count > 0))"
      Krikri::ConditionalEvaluator.evaluate(cond, v, strict: true, raise_undefined: true).should be_false
    end

    it "evaluates leading 'not'" do
      v = vars({"a" => false} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("not a", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate(%(not a or "x" in undefined_var.stdout), v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate("my_list", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("my_dict", v).should be_false
    end

    it "treats a non-empty list/dict as truthy" do
      v = Hash(String, JSON::Any).new
      v["my_list"] = JSON.parse(%(["a"]))
      v["my_dict"] = JSON.parse(%({"k": "v"}))
      Krikri::ConditionalEvaluator.evaluate("my_list", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("my_dict", v).should be_true
    end

    it "treats an empty list reached via a dotted path as falsy too" do
      v = Hash(String, JSON::Any).new
      v["nested"] = JSON.parse(%({"empty_list": []}))
      Krikri::ConditionalEvaluator.evaluate("nested.empty_list", v).should be_false
    end
  end

  describe "membership ('in')" do
    it "checks substring membership" do
      Krikri::ConditionalEvaluator.evaluate(%("ba" in "bar"), EMPTY_VARS).should be_true
    end

    it "checks 'not in' membership (os_hardening's su-binary gate)" do
      v = Hash(String, JSON::Any).new
      v["os_security_users_allow"] = JSON::Any.new(Array(JSON::Any).new)
      Krikri::ConditionalEvaluator.evaluate(%('change_user' not in os_security_users_allow), v).should be_true
    end

    it "'not in' is false when the list does contain the item" do
      v = Hash(String, JSON::Any).new
      v["os_security_users_allow"] = JSON::Any.new([JSON::Any.new("change_user")])
      Krikri::ConditionalEvaluator.evaluate(%('change_user' not in os_security_users_allow), v).should be_false
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
      Krikri::ConditionalEvaluator.evaluate(%('already in peer list' not in probe2.stdout), v).should be_false
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
      Krikri::ConditionalEvaluator.evaluate("result.rc in [0, 3, 4]", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("result.rc not in [0, 3, 4]", v).should be_false

      v["result"] = JSON.parse(%({"rc": 7}))
      Krikri::ConditionalEvaluator.evaluate("result.rc in [0, 3, 4]", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("result.rc not in [0, 3, 4]", v).should be_true
    end

    it "checks membership against a METHOD CALL (not just a bare variable or filter)" do
      # Real bug found benchmarking robertdebock.squid (round 48,
      # krikri-playbook 0.9.389): its own assert.yml has
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

      Krikri::ConditionalEvaluator.evaluate(
        %(squid_cache_dir.split(" ")[0] in [ "ufs", "aufs", "diskd", "rock", "null" ]), v
      ).should be_true

      v["squid_cache_dir"] = JSON::Any.new("bogus /var/spool/squid")
      Krikri::ConditionalEvaluator.evaluate(
        %(squid_cache_dir.split(" ")[0] in [ "ufs", "aufs", "diskd", "rock", "null" ]), v
      ).should be_false
    end
  end

  describe "out-of-line parentheses from list-when ANDing" do
    it "unwraps a fully parenthesized clause (each clause of a list-when)" do
      v = Hash(String, JSON::Any).new
      v["ansible_facts"] = JSON::Any.new({"os_family" => JSON::Any.new("Debian")})
      combined = %((ansible_facts.os_family != 'Suse') and (ansible_facts.os_family != 'Archlinux'))
      Krikri::ConditionalEvaluator.evaluate(combined, v).should be_true
    end

    it "does not unwrap a paren that is not a full wrap (trailing content)" do
      v = vars({"a" => "x"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(%((a == "x") and true), v).should be_true
    end
  end

  describe "definedness" do
    it "evaluates 'is defined' true for present variables" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("foo is defined", v).should be_true
    end

    it "evaluates 'is not defined' true for missing variables" do
      Krikri::ConditionalEvaluator.evaluate("foo is not defined", EMPTY_VARS).should be_true
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
      Krikri::ConditionalEvaluator.evaluate("check is failed", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("not check is failed", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("check is not failed", v).should be_false
    end

    it "'succeeded'/'success' are the inverse of 'failed', not a separate stored field" do
      v = Hash(String, JSON::Any).new
      v["check"] = JSON.parse(%({"failed": false, "changed": true}))
      Krikri::ConditionalEvaluator.evaluate("check is succeeded", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("check is success", v).should be_true

      v["check"] = JSON.parse(%({"failed": true}))
      Krikri::ConditionalEvaluator.evaluate("check is succeeded", v).should be_false
    end

    it "reads 'changed'/'skipped' off a registered result" do
      v = Hash(String, JSON::Any).new
      v["check"] = JSON.parse(%({"failed": false, "changed": true}))
      Krikri::ConditionalEvaluator.evaluate("check is changed", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("check is not skipped", v).should be_true
    end
  end

  describe "truthiness" do
    it "treats a bare true variable as truthy" do
      v = vars({"flag" => true} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("flag", v).should be_true
    end

    it "treats a bare false variable as falsy" do
      v = vars({"flag" => false} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("flag", v).should be_false
    end

    it "treats an undefined bare variable as falsy" do
      Krikri::ConditionalEvaluator.evaluate("missing", EMPTY_VARS).should be_false
    end

    it "treats a non-empty string as truthy" do
      v = vars({"name" => "x"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("name", v).should be_true
    end

    it "treats an empty string as falsy" do
      v = vars({"name" => ""} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate("name", v).should be_false
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
      Krikri::ConditionalEvaluator.evaluate("result.rc == 0", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("result.rc != 0", v).should be_false
    end

    it "resolves a two-level (nested) dotted field for truthiness" do
      v = Hash(String, JSON::Any).new
      v["stat_result"] = JSON.parse(%({"stat": {"exists": true}}))
      Krikri::ConditionalEvaluator.evaluate("stat_result.stat.exists", v).should be_true
    end

    it "treats a dotted field resolving to false as falsy" do
      v = Hash(String, JSON::Any).new
      v["stat_result"] = JSON.parse(%({"stat": {"exists": false}}))
      Krikri::ConditionalEvaluator.evaluate("stat_result.stat.exists", v).should be_false
    end

    it "treats a missing dotted field as undefined (falsy), not an error" do
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"rc": 0}))
      Krikri::ConditionalEvaluator.evaluate("result.nonexistent", v).should be_false
    end

    it "does not treat a float literal's decimal point as a dotted variable path" do
      # A float literal like "1.5" also contains a "." - without the
      # to_f64? guard, evaluate_value would split it into ["1", "5"] and,
      # if a variable literally named "1" happened to exist, resolve it as
      # a dotted lookup ("look up variable 1, then its nested field 5")
      # instead of treating "1.5" as the numeric literal it is.
      v = Hash(String, JSON::Any).new
      v["1"] = JSON.parse(%({"5": "unexpected"}))
      Krikri::ConditionalEvaluator.evaluate(%(1.5 == "unexpected"), v).should be_false
    end

    it "still evaluates a plain (non-dotted) variable normally" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate("mylist | length > 0", v).should be_true
    end

    it "evaluates false when the filtered value doesn't satisfy the comparison" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([] of JSON::Any)
      Krikri::ConditionalEvaluator.evaluate("mylist | length > 0", v).should be_false
    end

    it "evaluates a bare filter chain for truthiness (no comparison at all)" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b")])
      Krikri::ConditionalEvaluator.evaluate("mylist | length", v).should be_true

      v["mylist"] = JSON::Any.new([] of JSON::Any)
      Krikri::ConditionalEvaluator.evaluate("mylist | length", v).should be_false
    end

    it "evaluates a filter chain on a dotted (nested) operand" do
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"stdout": "  hello  "}))
      Krikri::ConditionalEvaluator.evaluate(%(result.stdout | trim == "hello"), v).should be_true
    end

    it "evaluates a chained (multi-filter) pipeline as a comparison operand" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("b"), JSON::Any.new("a")])
      Krikri::ConditionalEvaluator.evaluate(%(mylist | sort | join(',') == "a,b"), v).should be_true
    end

    it "combines a filter-chain comparison with and/or without regressing existing operators" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
      Krikri::ConditionalEvaluator.evaluate("mylist | length > 0 and mylist | length == 3", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate("vault_enterprise", v).should be_false

      ENV["CRYSTAL_ANSIBLE_SPEC_COND_ENV_TEST"] = "true"
      Krikri::ConditionalEvaluator.evaluate("vault_enterprise", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate(%(('linux-' + go_arch + '.tar.gz') in item), v).should be_true
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

      Krikri::ConditionalEvaluator.evaluate("a_dict is mapping", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_list is mapping", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("a_list is sequence", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_dict is not sequence", v).should be_true
      # A bare String deliberately does NOT match `is sequence` - every
      # real playbook using this pattern means "is this a list", and
      # matching String too (technically valid Python/Jinja2 semantics,
      # since strings are iterable) would make `is not sequence` wrongly
      # reject ordinary string variables.
      Krikri::ConditionalEvaluator.evaluate("a_string is not sequence", v).should be_true
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

      Krikri::ConditionalEvaluator.evaluate("a_bool is boolean", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("an_int is boolean", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("an_int is number", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_float is number", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("an_int is integer", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_float is integer", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("a_float is float", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_string is string", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("an_int is string", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("a_list is iterable", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_string is iterable", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("an_int is not iterable", v).should be_true
    end

    it "evaluates a type test against a FILTER CHAIN, not just a bare variable" do
      # Real bug found benchmarking robertdebock.java (round 45,
      # krikri-playbook 0.9.388): its own assert.yml has `java_version |
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

      Krikri::ConditionalEvaluator.evaluate("java_version | int is number", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("java_version | int in [6, 7, 8, 9, 10, 11, 12, 13, 17, 19, 20, 21]", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("java_version | int in [6, 7, 8]", v).should be_false
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

      Krikri::ConditionalEvaluator.evaluate("a_string is none", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("a_string is not none", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a_null is none", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate(%(version is match("latest")), v).should be_true
      Krikri::ConditionalEvaluator.evaluate(%(version is not match("late")), v).should be_false
      Krikri::ConditionalEvaluator.evaluate(%(version is match("^lat")), v).should be_true
      Krikri::ConditionalEvaluator.evaluate(%(version is match("stable")), v).should be_false

      # search() matches anywhere in the string (Python's re.search).
      Krikri::ConditionalEvaluator.evaluate(%(path is search("\\d+\\.\\d+\\.\\d+")), v).should be_true
      Krikri::ConditionalEvaluator.evaluate(%(path is not search("nomatch")), v).should be_true
    end

    it "evaluates 'is subset(...)' / 'is superset(...)' / 'is contains(...)' (plus negations)" do
      v = Hash(String, JSON::Any).new
      v["small"] = JSON.parse(%(["a", "b"]))
      v["big"] = JSON.parse(%(["a", "b", "c"]))
      v["items"] = JSON.parse(%(["x", "y", "z"]))

      Krikri::ConditionalEvaluator.evaluate("small is subset(big)", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("big is subset(small)", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("big is superset(small)", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("small is not superset(big)", v).should be_true
      Krikri::ConditionalEvaluator.evaluate(%(items is contains("y")), v).should be_true
      Krikri::ConditionalEvaluator.evaluate(%(items is not contains("q")), v).should be_true
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

      Krikri::ConditionalEvaluator.evaluate("f is exists", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("f is file", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("f is not directory", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("d is directory", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("l is link", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("missing is not exists", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("l is link_exists", v).should be_true

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

      Krikri::ConditionalEvaluator.evaluate("a is same_file(b)", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("a is not same_file(c)", v).should be_true

      File.delete(path1)
      File.delete(path2)
    end

    it "evaluates 'is mount' against the CONTROLLER's real mount table" do
      v = Hash(String, JSON::Any).new
      v["root"] = JSON::Any.new("/")
      v["notmount"] = JSON::Any.new("/no/such/mountpoint/at/all")

      Krikri::ConditionalEvaluator.evaluate("root is mount", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("notmount is not mount", v).should be_true
    end

    it "evaluates 'is vault_encrypted' / 'is vaulted_file'" do
      path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "conditional_vault_test.txt")
      encrypted = Krikri::Vault.encrypt("secret", "password123")
      File.write(path, encrypted)

      v = Hash(String, JSON::Any).new
      v["ciphertext"] = JSON::Any.new(encrypted)
      v["plain"] = JSON::Any.new("not encrypted")
      v["path"] = JSON::Any.new(path)

      Krikri::ConditionalEvaluator.evaluate("ciphertext is vault_encrypted", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("plain is not vault_encrypted", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("path is vaulted_file", v).should be_true

      File.delete(path)
    end

    it "evaluates 'is urn'" do
      v = Hash(String, JSON::Any).new
      v["good"] = JSON::Any.new("urn:isbn:0451450523")
      v["bad"] = JSON::Any.new("not-a-urn")

      Krikri::ConditionalEvaluator.evaluate("good is urn", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("bad is not urn", v).should be_true
    end

    it "evaluates 'is started' / 'is finished' / 'is timedout' / 'is reachable' / 'is unreachable' on a registered result dict (int 0/1, not bool)" do
      v = Hash(String, JSON::Any).new
      v["job"] = JSON.parse(%({"started": 1, "finished": 0}))
      v["conn"] = JSON.parse(%({"unreachable": true}))
      v["conn_ok"] = JSON.parse(%({"unreachable": false}))

      Krikri::ConditionalEvaluator.evaluate("job is started", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("job is not finished", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("conn is unreachable", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("conn is not reachable", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("conn_ok is reachable", v).should be_true
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

      Krikri::ConditionalEvaluator.evaluate("odd_n is not divisibleby 2", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("even_n is not divisibleby 2", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("even_n is divisibleby 2", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("odd_n is divisibleby 2", v).should be_false
    end

    it "falls back to Crinja for a bare function-call condition (lookup(...), query(...), etc)" do
      # Real bug found benchmarking devsec.hardening.os_hardening's own
      # `when: not lookup('varnames', '^' + item.key + '$')` (looped
      # once per OS-family variable the role loads, deciding whether to
      # skip a set_fact: for a name the user already defined).
      # #evaluate_value has no notion of function-call syntax at all, so
      # a bare `lookup(...)` condition (not wrapped in an `is <test>`,
      # the only other Crinja-delegation trigger this module has) fell
      # through to #evaluate_truthiness, which resolved the condition
      # TEXT as an undefined variable NAME - the lookup call itself was
      # never actually invoked, so both `lookup(...)` and
      # `not lookup(...)` evaluated to the same result regardless of
      # what the lookup actually returned (proof the call wasn't
      # running, not just returning the wrong answer). Left every
      # OS-family package/config variable the role loads (e.g.
      # `auditd_package`) undefined for the rest of the role, failing
      # its very first real task ("Unable to locate package undefined").
      v = Hash(String, JSON::Any).new
      v["my_defined_var"] = JSON::Any.new("hello")

      Krikri::ConditionalEvaluator.evaluate("not lookup('varnames', '^totally_undefined_var$')", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("not lookup('varnames', '^my_defined_var$')", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("lookup('varnames', '^totally_undefined_var$')", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("lookup('varnames', '^my_defined_var$')", v).should be_true
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

      Krikri::ConditionalEvaluator.evaluate("grafana_security.admin_user is defined", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("grafana_security.admin_user is not defined", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("grafana_security.admin_password is not defined", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate("templated_dict is mapping", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate("outer.inner == 'resolved'", v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate(%(mount_requests | regex_search("swap")), v).should be_false

      v["mount_requests"] = JSON.parse(%([{"path": "swap", "fstype": "swap"}]))
      Krikri::ConditionalEvaluator.evaluate(%(mount_requests | regex_search("swap")), v).should be_true
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
      Krikri::ConditionalEvaluator.evaluate(
        "item.size_available | int >= kilobytes_available | int", v
      ).should be_true
    end
  end

  describe "strict: true (changed_when:/failed_when: semantics)" do
    # Real bug found benchmarking robertdebock.cve_2024_3094:
    # `failed_when: xz_version.stdout | ansible.builtin.regex_search("5\.6\.(0|1)")`
    # on an unaffected xz version (no regex match, regex_search returns
    # None). Real Ansible's changed_when:/failed_when: (unlike when:,
    # which freely truthy-converts) require the templated result to
    # already be a real boolean - a None specifically raises "Conditional
    # result (...) was derived from value of type 'NoneType'.
    # Conditionals must have a boolean result." and fails the task,
    # rather than being silently truthy-converted to false. Verified live
    # against real ansible-playbook (Rocky 9.6): py failed rc=2, crystal
    # (pre-fix) silently passed rc=0.
    it "raises on a bare filter expression that resolves to None" do
      v = Hash(String, JSON::Any).new
      v["xz_version"] = JSON.parse(%({"stdout": "xz (XZ Utils) 5.2.5"}))
      expect_raises(Krikri::ConditionalEvaluator::ConditionalBooleanError) do
        Krikri::ConditionalEvaluator.evaluate(
          %(xz_version.stdout | regex_search("5\\.6\\.(0|1)")), v, strict: true
        )
      end
    end

    it "does not raise for the same expression under when: semantics (strict: false)" do
      v = Hash(String, JSON::Any).new
      v["xz_version"] = JSON.parse(%({"stdout": "xz (XZ Utils) 5.2.5"}))
      Krikri::ConditionalEvaluator.evaluate(
        %(xz_version.stdout | regex_search("5\\.6\\.(0|1)")), v
      ).should be_false
    end

    # Real bug found benchmarking andrewrothstein.docker_engine (0.9.612
    # regression, fixed in 0.9.613): a list-form `when:` clause whose
    # items are plain `x | bool` filter chains. Each item is evaluated as
    # its own bare condition with strict: true - #evaluate_value's filter-
    # chain branch renders it via ExpressionEvaluator (Python-repr text,
    # "True"/"False") and then tried JSON.parse on that text, which isn't
    # valid JSON, so it fell back to wrapping the literal string "True" -
    # the strict check two callers up then raised "Conditional result
    # (True) was derived from value of type 'str'" even though the
    # operand really was boolean. Verified live: real ansible-core 2.19.12
    # runs the handler; crystal (pre-fix) hard-failed it.
    it "does not raise for a bare `x | bool` filter chain that resolves to a real boolean" do
      v = Hash(String, JSON::Any).new
      v["docker_engine_manage_service"] = JSON::Any.new("yes")
      Krikri::ConditionalEvaluator.evaluate(
        "docker_engine_manage_service | bool", v, strict: true
      ).should be_true
    end

    # Real bug found benchmarking jdauphant.dns's own "Ensure dns
    # servers are configured in dhclient.conf" task: `when:
    # dns_forced_in_dhclientconf and item.value != ""`, where
    # dns_forced_in_dhclientconf DEFAULTS to a whole-value template
    # (`"{{ansible_os_family == 'Debian' or ansible_os_family ==
    # 'Redhat'}}"`). Real Ansible's Jinja2-native templating preserves
    # the boolean TYPE all the way through variable storage for a
    # whole-value template like this; this codebase's string-based
    # substitution renders the SAME semantic value as the literal text
    # "True" instead - previously indistinguishable from a genuinely
    # non-boolean string (which real Ansible DOES correctly reject
    # under ansible-core 2.19's strict conditional-boolean requirement)
    # and always raised, even for the plain bare-variable idiom (`when:
    # dns_forced_in_dhclientconf` alone), not just combined via `and`.
    it "does not raise for a bare variable whose value is the string \"True\"/\"False\"" do
      v = Hash(String, JSON::Any).new
      v["dns_forced_in_dhclientconf"] = JSON::Any.new("True")
      Krikri::ConditionalEvaluator.evaluate(
        "dns_forced_in_dhclientconf", v, strict: true
      ).should be_true

      v["dns_forced_in_dhclientconf"] = JSON::Any.new("False")
      Krikri::ConditionalEvaluator.evaluate(
        "dns_forced_in_dhclientconf", v, strict: true
      ).should be_false
    end

    it "does not raise for that same boolean-string variable combined via 'and'" do
      v = Hash(String, JSON::Any).new
      v["dns_forced_in_dhclientconf"] = JSON::Any.new("True")
      Krikri::ConditionalEvaluator.evaluate(
        %(dns_forced_in_dhclientconf and (1 == 1)), v, strict: true
      ).should be_true
    end

    it "still raises for a genuinely non-boolean string, unaffected by the True/False carve-out" do
      v = Hash(String, JSON::Any).new
      v["some_string"] = JSON::Any.new("hello")
      expect_raises(Krikri::ConditionalEvaluator::ConditionalBooleanError) do
        Krikri::ConditionalEvaluator.evaluate("some_string", v, strict: true)
      end
    end

    it "does not raise for a list-form when: made entirely of `| bool` filter chains" do
      v = Hash(String, JSON::Any).new
      v["a"] = JSON::Any.new("yes")
      v["b"] = JSON::Any.new("1")
      Krikri::ConditionalEvaluator.evaluate(
        "(a | bool) and (b | bool)", v, strict: true
      ).should be_true
    end

    # This used to assert that a MATCH does not raise, on the assumption
    # that a matching regex_search is "boolean-shaped". It is not: the
    # result is the matched STRING, and ansible-core 2.19 rejects any
    # non-boolean conditional result - verified live for both
    # `changed_when:` and `when:` with exactly this filter
    # ("Conditional result (True) was derived from value of type 'str'").
    it "raises for a matching filter too - the result is a string, not a bool" do
      v = Hash(String, JSON::Any).new
      v["xz_version"] = JSON.parse(%({"stdout": "xz (XZ Utils) 5.6.1"}))
      expect_raises(Krikri::ConditionalEvaluator::ConditionalBooleanError, /type 'str'/) do
        Krikri::ConditionalEvaluator.evaluate(
          %(xz_version.stdout | regex_search("5\\.6\\.(0|1)")), v, strict: true
        )
      end
    end

    it "does not raise for `not` over a None-yielding filter (Python `not` always yields a real bool)" do
      v = Hash(String, JSON::Any).new
      v["xz_version"] = JSON.parse(%({"stdout": "xz (XZ Utils) 5.2.5"}))
      Krikri::ConditionalEvaluator.evaluate(
        %(not xz_version.stdout | regex_search("5\\.6\\.(0|1)")), v, strict: true
      ).should be_true
    end
  end

  # Round 170 (2026-08-23): found via buluma.auditd's assert.yml. A bare
  # ternary (`X if COND else Y`) previously fell all the way through to
  # comparison-operator/truthiness handling since nothing recognized the
  # `if`/`else` syntax - a `<`/`==`/etc. inside the `X` branch got
  # misparsed as a top-level comparison spanning the WHOLE ternary
  # string, and even the branch-free `true if true else false` was wrong
  # (read as a bare-variable-name truthiness lookup on the literal text).
  describe "ternary (conditional) expressions" do
    it "evaluates the trivial true/false literal case" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate("true if true else false", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("false if true else true", v).should be_false
      Krikri::ConditionalEvaluator.evaluate("true if false else false", v).should be_false
    end

    it "does not misparse a comparison inside the true-branch as a top-level comparison" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate("1 < 2 if true else true", v).should be_true
      Krikri::ConditionalEvaluator.evaluate("1 > 2 if true else true", v).should be_false
    end

    it "matches buluma.auditd's real assert.yml expression" do
      v = Hash(String, JSON::Any).new
      v["auditd_admin_space_left"] = JSON::Any.new(50_i64)
      v["auditd_space_left"] = JSON::Any.new("75")
      Krikri::ConditionalEvaluator.evaluate(
        %((auditd_admin_space_left | int < auditd_space_left | int) if (auditd_space_left | string is not match(".*%")) else true), v
      ).should be_true
    end

    it "respects real Jinja precedence when the branches contain and/or" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate("true and false if true else true and true", v).should be_false
    end

    it "leaves a ternary nested inside parens for the recursive outer-paren unwrap" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate("true and (false if true else true)", v).should be_false
    end
  end

  describe "raise_undefined: true (task-level when: strict-undefined semantics)" do
    # Round 172 (buluma.git_tag, Rocky 9.6): `when: git_remote != '' and
    # git_remote != None` with git_remote genuinely undefined (no
    # default, never set anywhere). Real Ansible raises ("'git_remote'
    # is undefined") and fails the task; the pre-fix lenient evaluator
    # resolved both comparisons anyway (nil != '' -> true, nil != None
    # -> false) and evaluated the whole `and` as false, silently
    # skipping instead of failing.
    it "raises for a genuinely undefined bare variable reached through a comparison" do
      v = Hash(String, JSON::Any).new
      expect_raises(Krikri::ConditionalEvaluator::UndefinedVariableError) do
        Krikri::ConditionalEvaluator.evaluate(
          "git_remote != '' and git_remote != None", v, raise_undefined: true
        )
      end
    end

    it "does not raise for the same condition under when:'s normal lenient default (raise_undefined: false)" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate(
        "git_remote != '' and git_remote != None", v
      ).should be_false
    end

    it "does not raise once the variable is actually defined" do
      v = Hash(String, JSON::Any).new
      v["git_remote"] = JSON::Any.new("origin")
      Krikri::ConditionalEvaluator.evaluate(
        "git_remote != '' and git_remote != None", v, raise_undefined: true
      ).should be_true
    end

    it "does not raise for the Python/Jinja None literal itself, only for a real undefined variable" do
      v = Hash(String, JSON::Any).new
      v["myvar"] = JSON::Any.new(nil)
      Krikri::ConditionalEvaluator.evaluate("myvar == None", v, raise_undefined: true).should be_true
      Krikri::ConditionalEvaluator.evaluate("myvar == none", v, raise_undefined: true).should be_true
    end

    it "raises for a genuinely undefined variable reached through bare truthiness" do
      v = Hash(String, JSON::Any).new
      expect_raises(Krikri::ConditionalEvaluator::UndefinedVariableError) do
        Krikri::ConditionalEvaluator.evaluate("totally_undefined_var", v, raise_undefined: true)
      end
    end

    it "raises for a genuinely undefined dotted path whose root is also undefined" do
      v = Hash(String, JSON::Any).new
      expect_raises(Krikri::ConditionalEvaluator::UndefinedVariableError) do
        Krikri::ConditionalEvaluator.evaluate("some_result.stdout == 'x'", v, raise_undefined: true)
      end
    end

    it "does NOT raise when the undefined operand goes through a filter/default() - still lenient by design" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate(
        "git_remote | default('') != ''", v, raise_undefined: true
      ).should be_false
    end

    it "short-circuits 'or' so an undefined second operand never raises when the first is already true" do
      v = Hash(String, JSON::Any).new
      v["already_true"] = JSON::Any.new(true)
      Krikri::ConditionalEvaluator.evaluate(
        "already_true or totally_undefined_var", v, raise_undefined: true
      ).should be_true
    end

    it "short-circuits 'and' so an undefined second operand never raises when the first is already false" do
      v = Hash(String, JSON::Any).new
      v["already_false"] = JSON::Any.new(false)
      Krikri::ConditionalEvaluator.evaluate(
        "already_false and totally_undefined_var", v, raise_undefined: true
      ).should be_false
    end

    it "still evaluates 'is defined' on the undefined variable itself without raising" do
      v = Hash(String, JSON::Any).new
      Krikri::ConditionalEvaluator.evaluate(
        "totally_undefined_var is not defined", v, raise_undefined: true
      ).should be_true
    end
  end

  describe "bare float literal in a comparison" do
    # Real bug found benchmarking buluma.p10k (0.9.615): `when:
    # zsh_version.stdout | float < 5.1`. #evaluate_value had a case for
    # bare INT literals ("3") but none for a bare float literal ("5.1") -
    # it fell through to the plain variable-lookup branch, found no var
    # literally named "5.1", and raised "'5.1' is undefined" under
    # raise_undefined (task-level when: strictness) even though real
    # Ansible evaluates the comparison fine.
    it "does not raise 'is undefined' for a bare float literal operand" do
      v = Hash(String, JSON::Any).new
      v["zsh_version"] = JSON.parse(%({"stdout": "4.9"}))
      Krikri::ConditionalEvaluator.evaluate(
        "zsh_version.stdout | float < 5.1", v, raise_undefined: true
      ).should be_true
    end

    it "compares floats numerically, not lexicographically, on both sides of '<'" do
      v = Hash(String, JSON::Any).new
      v["zsh_version"] = JSON.parse(%({"stdout": "10.2"}))
      # Lexicographic "10.2" <=> "5.1" would wrongly say 10.2 < 5.1 (the
      # '1' < '5' first-character comparison) - #compare_values needs a
      # real numeric float fallback once the int64 attempt fails for both
      # sides, not just for the literal-recognition fix above.
      Krikri::ConditionalEvaluator.evaluate(
        "zsh_version.stdout | float < 5.1", v, raise_undefined: true
      ).should be_false
    end
  end

  describe "round 189 regressions" do
    it "evaluates a YAML folded-scalar condition with embedded newlines from more-indented continuation lines" do
      # mrlesmithjr.network-tweaks: `(a is defined and\n  a) and (item.set is\n  #   defined and\n    item.set)` - real newlines in the condition string silently
      # evaluated FALSE for every loop item before the whitespace
      # normalizer; real Ansible (real Python parser) runs them.
      v = vars({"a" => true} of String => JSON::Any::Type)
      condition = "(a is defined and\n              a) and\n              (b is defined and\n                b)"
      v2 = vars({"a" => true, "b" => true} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(condition, v2).should be_true
      v3 = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      Krikri::ConditionalEvaluator.evaluate(condition, v3).should be_false
      # untouched single-space conditions still work
      Krikri::ConditionalEvaluator.evaluate("a is defined and a", v).should be_true
    end

    it "treats a regex_search no-match as None for `is not none` (filter chain over a registered result)" do
      # buluma.cve_2024_3094: `(xz_version.stdout | regex_search("5\\.6\\.(0|1)")) is not none`
      # must be FALSE when the regex does not match - the old "undefined"
      # sentinel string made it TRUE and failed a succeeding task.
      v = vars({"a" => true} of String => JSON::Any::Type)
      v["xz_version"] = JSON::Any.new({"stdout" => JSON::Any.new("xz (XZ Utils) 5.2.5\nliblzma 5.2.5")})
      Krikri::ConditionalEvaluator.evaluate(
        %(xz_version.stdout | ansible.builtin.regex_search("5\\.6\\.(0|1)") is not none), v
      ).should be_false
      # and TRUE when it does match
      v_hit = vars({"a" => true} of String => JSON::Any::Type)
      v_hit["xz_version"] = JSON::Any.new({"stdout" => JSON::Any.new("xz (XZ Utils) 5.6.0")})
      Krikri::ConditionalEvaluator.evaluate(
        %(xz_version.stdout | ansible.builtin.regex_search("5\\.6\\.(0|1)") is not none), v_hit
      ).should be_true
    end
  end
end

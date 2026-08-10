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
  end
end

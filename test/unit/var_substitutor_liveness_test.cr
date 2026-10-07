require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# Invalidation regressions for templating against LIVE vars.
#
# The controller-profile candidate-2 work made VarSubstitutor cheap to
# construct (copy-on-write: the magic-var additions are skipped when
# they would be verified no-ops, leaving @vars aliased to the caller's
# hash and read live) instead of caching substitutor instances. The
# executor's invalidation discipline - which every call site follows -
# is CONSTRUCT A FRESH SUBSTITUTOR after any vars mutation (set_fact,
# register, loop item binding, include_vars, until:-retry): see
# run_until_retries, the per-item loop sites, finish_single_task. These
# specs pin that discipline's contract: a substitution performed AFTER
# a mutation renders the CURRENT value, never a snapshot taken earlier
# in the same task. A caching layer that returns a substitutor built
# before the mutation (keyed only by the vars hash's identity, without
# an invalidation signal) fails every spec here - and the playbook-level
# twins in test/integration/vars_invalidation_templating_test.cr pin the
# same property end-to-end through the executor.
#
# Deliberately NOT pinned here: visibility of mutations through a single
# REUSED substitutor instance. The engine's per-instance components
# (the jinja resolver's per-name prepared-value cache, built lazily on
# first read) predate this work and are only invalidated by #set_
# variable; the executor never reuses an instance across a mutation, so
# the observable contract is the fresh-instance one pinned below.
describe "templating sees vars mutations between substitutions" do
  def base_vars : Hash(String, JSON::Any)
    h = Hash(String, JSON::Any).new
    h["inventory_hostname"] = JSON::Any.new("web1")
    h["ansible_host"] = JSON::Any.new("web1")
    h
  end

  it "a fresh instance after a set_fact-style value change renders the new value" do
    vars = base_vars
    vars["x"] = JSON::Any.new("before")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("{{ x }}").must_equal("before")

    vars["x"] = JSON::Any.new("after")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("{{ x }}").must_equal("after")
  end

  it "a fresh instance after a value is REMOVED renders the default fallback" do
    vars = base_vars
    vars["x"] = JSON::Any.new("before")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("{{ x }}").must_equal("before")

    vars.delete("x")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("{{ x | default('GONE') }}").must_equal("GONE")
  end

  it "a fresh instance after a set_fact-style dict is replaced renders the new dict" do
    vars = base_vars
    vars["cfg"] = JSON.parse(%({"a": 1}))
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("{{ cfg.a }}").must_equal("1")

    vars["cfg"] = JSON.parse(%({"a": 2}))
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("{{ cfg.a }}").must_equal("2")
  end

  it "loop-item rebinding between two fresh instances is visible" do
    vars = base_vars
    vars["item"] = JSON::Any.new("one")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("item={{ item }}").must_equal("item=one")

    vars["item"] = JSON::Any.new("two")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("item={{ item }}").must_equal("item=two")
  end

  it "register-style result replacement between two fresh instances is visible" do
    vars = base_vars
    vars["r"] = JSON.parse(%({"stdout": "one", "changed": false}))
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("got={{ r.stdout }}").must_equal("got=one")

    vars["r"] = JSON.parse(%({"stdout": "two", "changed": false}))
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("got={{ r.stdout }}").must_equal("got=two")
  end

  it "include_vars-style key addition between two fresh instances is visible" do
    vars = base_vars
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("iv={{ iv | default('ABSENT') }}").must_equal("iv=ABSENT")

    vars["iv"] = JSON::Any.new("loaded")
    Krikri::VarSubstitutor.new(vars: vars, host_name: "web1")
      .substitute("iv={{ iv }}").must_equal("iv=loaded")
  end
end

require "../spec_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/conditional_evaluator"
# The P2 registrations live in the GLOBAL Crinja default library, but this
# file is only pulled in by the template action plugin - a spec that requires
# only variable_substitutor sees a BARE Crinja env, so both "engines" would
# error identically and any parity assertion would be vacuously true. Load
# the registrations explicitly so the pure side sees the real feature set.
require "../../src/krikri/krikri_jinja_filters"
require "../../src/krikri/krikri_jinja_filters"

# P2.16 (FINDINGS_CHECKLIST.md) - the cross-engine parity matrix.
#
# One table driving EVERY feature the Pattern-2 batches registered into
# Crinja's global default library through ALL of the engines this codebase
# can reach it with:
#
#   1. a PURE `Crinja.new` environment (what a plain template render sees),
#   2. krikri-playbook's real render path (`VarSubstitutor#substitute`, the
#      hand-rolled ExpressionEvaluator + FilterEngine with its Crinja
#      delegation),
#   3. the hand-rolled `ConditionalEvaluator` (`when:`/`assert:` conditions),
#      for the test spellings that path can reach.
#
# This project's whole bug history is the two engines DIVERGING (see
# CLAUDE.md: they share no implementation, so every fix lands twice). This
# file turns a future divergence on any of these registrations - or a new
# resolution path that resolves one of them differently - into a failing
# test here instead of a benchmark round.
#
# Every expected value was verified against the engines' actual current
# (ansible-core-2.19.4-conformant) behavior; where a difference between the
# engines is justified, it is asserted and commented, not skipped.

private def pv(pairs : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
  pairs
end

private def parity_vars : Hash(String, JSON::Any)
  h = Hash(String, JSON::Any).new
  h["small"] = JSON.parse(%(["a", "b"]))
  h["big"] = JSON.parse(%(["a", "b", "c"]))
  # A freshly created plain file, not a well-known path: inside a job
  # container /etc/hosts is itself a bind mount (GitHub Actions, any
  # Docker run), so `is_mount` on it would legitimately be True there
  # and the False expectation would only hold on a dev box.
  plain_file = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "p2-parity-plain-file.txt")
  File.delete(plain_file) if File.exists?(plain_file)
  File.write(plain_file, "plain file for the is_mount=False row\n")
  at_exit do
    File.delete(plain_file) if File.exists?(plain_file)
  end
  h["real_file"] = JSON::Any.new(plain_file)
  h["real_dir"] = JSON::Any.new("/etc")
  h["rel_path"] = JSON::Any.new("etc/hosts")
  h["flag"] = JSON::Any.new("true")
  h["bool_flag"] = JSON::Any.new(true)
  h["empty"] = JSON::Any.new("")
  h["text"] = JSON::Any.new("hello")
  h["int_val"] = JSON::Any.new(7)
  h["float_nan"] = JSON::Any.new(Float64::NAN)
  h["web_url"] = JSON::Any.new("https://example.com/a?b=c")
  h["not_url"] = JSON::Any.new("not a url at all")
  h["list"] = JSON.parse(%(["x", "y", "z"]))
  h["dict_var"] = JSON.parse(%({"a": 1, "b": 2}))
  h["ts"] = JSON::Any.new("2024-03-05 07:08:09")
  h["users"] = JSON.parse(%([{"name": "root", "keys": ["k1", "k2"]}, {"name": "bob", "keys": ["k3"]}]))
  h
end

# The fork's `Template#render(bindings)` wraps each value in
# `Crinja::Value.new` directly and JSON::Any is not a supported raw type, so
# the pure side gets the vars through the SAME converter the engine's own
# context uses (`JinjaRenderer.json_any_to_crinja_value`) - that way both
# engines see byte-identical data, which is the parity this file exists to
# assert.
# The template engine a real `.j2` render uses: the shared krikri-jinja
# engine with krikri's Ansible registrations.
private def pure_crinja(tpl : String) : String
  KrikriJinja.render(tpl, parity_vars.transform_values { |json| KrikriJinja.from_json_any(json) })
rescue e
  "ERR: #{e.message}"
end

private def engine_substitute(tpl : String) : String
  Krikri::VarSubstitutor.new(vars: parity_vars, host_name: "h").substitute(tpl)
rescue e
  "ERR: #{e.message}"
end

private def conditional(expr : String) : String
  Krikri::ConditionalEvaluator.evaluate(expr, parity_vars).to_s
rescue e
  "ERR: #{e.message}"
end

describe "P2.16 cross-engine parity matrix" do
  # {label, template, expected} - expected is the agreed output of BOTH
  # engines; a row where the engines disagree fails, which is the point.
  matrix = {
    # ---- tests registered by the P2 batches (P2.1-P2.7) ----
    "issubset positive"                        => {"{{ small is issubset(big) }}", "True"},
    "issuperset positive"                      => {"{{ big is issuperset(small) }}", "True"},
    "is_file"                                  => {"{{ real_file is is_file }}", "True"},
    "is_dir"                                   => {"{{ real_dir is is_dir }}", "True"},
    "is_link on a regular file"                => {"{{ real_file is is_link }}", "False"},
    "is_abs positive"                          => {"{{ real_file is is_abs }}", "True"},
    "is_abs negative"                          => {"{{ rel_path is is_abs }}", "False"},
    "is_mount on a plain file"                 => {"{{ real_file is is_mount }}", "False"},
    "is_same_file identity"                    => {"{{ real_file is is_same_file(real_file) }}", "True"},
    "true test on a real Bool"                 => {"{{ bool_flag is true }}", "True"},
    "false test on a real Bool"                => {"{{ bool_flag is false }}", "False"},
    "falsy on empty string"                    => {"{{ empty is falsy }}", "True"},
    "true is boolean IDENTITY, not truthiness" => {"{{ text is true }}", "False"},
    "bool-literal test name (is not false)"    => {"{{ flag is not false }}", "True"},
    # `abs` is Ansible's absolute-path test (a number fails the task).
    "abs-as-test on an absolute path"          => {"{{ real_dir is abs }}", "True"},
    "abs-as-test on a relative path"           => {"{{ rel_path is abs }}", "False"},
    "isnan on a NaN float"                     => {"{{ float_nan is isnan }}", "True"},
    "nan on a real number"                     => {"{{ int_val is nan }}", "False"},
    "uri test positive"                        => {"{{ web_url is uri }}", "True"},
    "uri test negative"                        => {"{{ not_url is uri }}", "False"},
    "url test positive"                        => {"{{ web_url is url }}", "True"},
    # The name is the tested VALUE (`'upper' is filter`); real ansible-core
    # fails `text is filter('upper')` outright.
    "filter meta-test (registered name)"       => {"{{ 'upper' is filter }}", "True"},
    "filter meta-test (unknown name)"          => {"{{ 'nosuchfilter' is filter }}", "False"},
    "test meta-test (registered name)"         => {"{{ 'defined' is test }}", "True"},
    # ---- filters registered by the P2 batches (P2.8-P2.14) ----
    # "strftime after to_datetime" left the matrix: ansible-core 2.19
    # changed strftime's argument order (piped value = FORMAT, epoch =
    # first argument), so the old `ts | to_datetime | strftime('%H:%M')`
    # idiom now FAILS upstream ("Invalid value for epoch value",
    # live-verified against 2.19.11). The two engines' error CHANNELS
    # format that failure differently (pure Crinja appends its template
    # excerpt), so a byte-equality matrix entry can't hold; the 2.19
    # semantics are pinned in filter_batch2_spec's strftime block
    # instead.
    "subelements result length"  => {"{{ users | subelements('keys') | length }}", "3"},
    "count alias of length"      => {"{{ list | count }}", "3"},
    "d alias of default"         => {"{{ missing_var | d('fallback') }}", "fallback"},
    "items alias of dict2items"  => {"{{ dict_var | items | length }}", "2"},
    "root path prefix"           => {"{{ '/etc/hosts' | root }}", "/"},
  }

  matrix.each do |label, (tpl, expected)|
    it "#{label}: pure Crinja == engine substitute == expected" do
      pure = pure_crinja(tpl)
      engine = engine_substitute(tpl)
      # The parity assertion itself: the two engines must agree.
      engine.should eq(pure)
      # And both must produce the documented (ansible-core-2.19.4-verified)
      # value, so a silent wrong-value regression can't hide behind an
      # agreement.
      pure.should eq(expected)
    end
  end

  # The hand-rolled ConditionalEvaluator is the engine's OTHER Jinja
  # implementation (`when:`/`assert:` conditions) - every test spelling
  # above that a condition can express must agree with pure Crinja there
  # too, and answer real booleans rather than strings.
  conditionals = {
    "issubset"   => "small is issubset(big)",
    "issuperset" => "big is issuperset(small)",
    "is_file"    => "real_file is is_file",
    "is_dir"     => "real_dir is is_dir",
    "is_abs"     => "real_file is is_abs",
    "true"       => "bool_flag is true",
    "false"      => "bool_flag is false",
    "falsy"      => "empty is falsy",
    "isnan"      => "float_nan is isnan",
    "uri"        => "web_url is uri",
  }
  conditionals.each do |label, expr|
    it "conditional evaluator agrees on '#{label}'" do
      expected = pure_crinja("{{ #{expr} }}") == "True"
      Krikri::ConditionalEvaluator.evaluate(expr, parity_vars).should eq(expected)
    end
  end

  # The truthiness trap, asserted as parity in BOTH engines: a Bool that
  # arrived as the STRING "true" (a real shape in this engine's JSON-typed
  # pipeline) is NOT boolean-identity-true - `is true` is False in the pure
  # env, in the engine's `{{ }}` path AND in the hand-rolled
  # ConditionalEvaluator. Only a real Bool satisfies it.
  describe "boolean identity is not truthiness, in every engine" do
    it "a string \"true\" fails `is true` in the engine path" do
      engine_substitute("{{ flag is true }}").should eq("False")
    end

    it "a string \"true\" fails `is true` in pure Crinja" do
      pure_crinja("{{ flag is true }}").should eq("False")
    end

    it "a string \"true\" fails `is true` in the conditional evaluator" do
      Krikri::ConditionalEvaluator.evaluate("flag is true", parity_vars).should be_false
    end

    it "a real Bool passes `is true` in all three engines" do
      engine_substitute("{{ bool_flag is true }}").should eq("True")
      pure_crinja("{{ bool_flag is true }}").should eq("True")
      Krikri::ConditionalEvaluator.evaluate("bool_flag is true", parity_vars).should be_true
    end
  end
end

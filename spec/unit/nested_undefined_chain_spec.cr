require "../spec_helper"
require "../../src/crystal_play/variable_substitutor"
require "../../src/crystal_play/conditional_evaluator"

# Real bug found round 180 benchmarking buluma.phpmyadmin on Ubuntu:
# a role default computed from ANOTHER, genuinely-never-set variable
# (`phpmyadmin_mysql_password: "{{ mysql_root_password }}"`, with
# `mysql_root_password` supplied by neither the role nor the playbook)
# silently rendered as the literal text "undefined" and the run
# continued - writing the seven-character string "undefined" into
# phpMyAdmin's config as the real MySQL password - where real Ansible
# fails the task ("'mysql_root_password' is undefined", reported
# against the DEFAULTS file, not the task's own reference).
#
# Root cause: the STRICT caller's strictness (module-arg finalization)
# stopped at the first level. `{{ phpmyadmin_mysql_password }}` found a
# perfectly real @vars entry and passed, then the inner recursive
# re-render ran LENIENTLY and collapsed the missing innermost name to
# this codebase's own "undefined" sentinel text - baked in as if it
# were legitimate content.
#
# Every expectation below was verified against real ansible-core 2.19.4
# running the equivalent playbook, not assumed.
describe "nested undefined chains" do
  describe "strict substitution follows the chain" do
    it "raises naming the INNERMOST missing variable, not the one referenced" do
      vars = {"pw" => JSON::Any.new("{{ mysql_root_password }}")}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(CrystalPlay::UndefinedVariableError, /'mysql_root_password' is undefined/) do
        sub.substitute("pw is [{{ pw }}]", strict: true)
      end
    end

    it "follows a chain more than one level deep" do
      vars = {
        "outer"  => JSON::Any.new("{{ middle }}"),
        "middle" => JSON::Any.new("{{ innermost }}"),
      }
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(CrystalPlay::UndefinedVariableError, /'innermost' is undefined/) do
        sub.substitute("[{{ outer }}]", strict: true)
      end
    end

    it "raises for a PARTIAL string value, not just a whole-value reference" do
      vars = {"partial" => JSON::Any.new("prefix-{{ missing_name }}-suffix")}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(CrystalPlay::UndefinedVariableError, /'missing_name' is undefined/) do
        sub.substitute("[{{ partial }}]", strict: true)
      end
    end

    it "raises for an undefined leaf reached through a list-of-dicts" do
      vars = {"entries" => JSON.parse(%([{"name": "a", "pw": "{{ missing_name }}"}]))}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(CrystalPlay::UndefinedVariableError, /'missing_name' is undefined/) do
        sub.substitute("[{{ entries[0].pw }}]", strict: true)
      end
    end

    it "does NOT raise when the chain bottoms out at a real value" do
      vars = {
        "outer" => JSON::Any.new("{{ inner }}"),
        "inner" => JSON::Any.new("realvalue"),
      }
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("[{{ outer }}]", strict: true).should eq("[realvalue]")
    end

    it "does NOT raise when the chain bottoms out at an empty string" do
      vars = {
        "outer" => JSON::Any.new("{{ inner }}"),
        "inner" => JSON::Any.new(""),
      }
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("[{{ outer }}]", strict: true).should eq("[]")
    end

    it "does NOT raise when the value guards its own missing name with default()" do
      vars = {"guarded" => JSON::Any.new("{{ missing_name | default('GUARDED') }}")}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("[{{ guarded }}]", strict: true).should eq("[GUARDED]")
    end

    it "leaves the lenient (non-strict) path untouched - still the 'undefined' sentinel" do
      # The leniency is load-bearing everywhere else in this engine
      # (when:, vars files, default() support); only the strict
      # module-arg caller changed.
      vars = {"pw" => JSON::Any.new("{{ mysql_root_password }}")}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("pw is [{{ pw }}]").should eq("pw is [undefined]")
    end
  end

  describe "the Crinja side treats such a chain as really Undefined" do
    it "lets default() fire, instead of returning the sentinel text" do
      vars = {"pw" => JSON::Any.new("{{ mysql_root_password }}")}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("[{{ pw | default('FALLBACK') }}]").should eq("[FALLBACK]")
    end

    it "answers `is defined` False, matching real Ansible" do
      vars = {"pw" => JSON::Any.new("{{ mysql_root_password }}")}
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("{{ pw is defined }}").should eq("False")
    end

    it "still answers `is defined` True for a chain that resolves" do
      vars = {
        "outer" => JSON::Any.new("{{ inner }}"),
        "inner" => JSON::Any.new("realvalue"),
      }
      sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("{{ outer is defined }}").should eq("True")
    end
  end

  describe "ConditionalEvaluator agrees with the Crinja side" do
    # The two Jinja evaluators in this codebase share no implementation
    # (see CLAUDE.md), so this same bug class has to be fixed - and
    # regression-tested - independently in each.
    it "treats an unresolvable chain as undefined for when: is defined" do
      vars = {"pw" => JSON::Any.new("{{ mysql_root_password }}")}
      CrystalPlay::ConditionalEvaluator.evaluate("pw is defined", vars).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("pw is undefined", vars).should be_true
    end

    it "still treats a resolvable chain as defined" do
      vars = {
        "outer" => JSON::Any.new("{{ inner }}"),
        "inner" => JSON::Any.new("realvalue"),
      }
      CrystalPlay::ConditionalEvaluator.evaluate("outer is defined", vars).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("outer is undefined", vars).should be_false
    end

    it "still treats an ordinary set variable as defined" do
      vars = {"plain" => JSON::Any.new("x")}
      CrystalPlay::ConditionalEvaluator.evaluate("plain is defined", vars).should be_true
    end
  end
end

require "../spec_helper"
require "../../src/krikri/variable_substitutor"
# The round-812045 specs below evaluate a real `regex_search` filter chain
# through the Crinja-first delegation path - without jinja_filters's own
# require-time `Crinja.filter` registration, Crinja raises
# UnknownFeatureError and the evaluator silently falls back to its
# hand-rolled path (the same bare-env gap filter_batch2_spec.cr documents).
require "../../src/krikri/jinja_filters"

# Real bug found benchmarking robertdebock.bios_update on Rocky 9.6 (round
# 161): real Ansible's Jinja2 templating for module args is
# strict-undefined by default - `debug: msg: "Error: {{ some_var }}"`
# where some_var is genuinely never set anywhere raises "Finalization of
# task args ... failed: 'some_var' is undefined" and fails the task. This
# engine otherwise renders a missing lookup as the literal string
# "undefined" and continues (a deliberate, pervasive leniency used
# throughout when:/changed_when:/failed_when: evaluation and most of
# VariableSubstitutor - NOT changed). `VarSubstitutor#substitute`'s new
# `strict:` parameter (used only by #substitute_task_params, the one
# place that assembles a task's final module-arg hash) narrowly re-adds
# real Ansible's strictness for the single most common, unambiguous
# shape of this bug: a BARE variable reference (`foo`, `foo.bar`,
# `foo['bar'][0]` - no filters/operators/function calls) that resolves to
# nothing.
describe Krikri::VarSubstitutor do
  describe "#substitute with strict: true" do
    it "raises UndefinedVariableError for a bare undefined top-level variable" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /'totally_undefined_var' is undefined/) do
        sub.substitute("Value: {{ totally_undefined_var }}", strict: true)
      end
    end

    it "raises UndefinedVariableError for a bare undefined dotted reference" do
      vars = {"bios_update_url" => JSON::Any.new("http://example.com")}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /'bios_update_download_bios_update_bootable_cd' is undefined/) do
        sub.substitute("Error: {{ bios_update_download_bios_update_bootable_cd }}", strict: true)
      end
    end

    it "does not raise when the variable is genuinely defined" do
      vars = {"name" => JSON::Any.new("alpha")}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("Value: {{ name }}", strict: true).should eq("Value: alpha")
    end

    it "does not raise when a dict key exists but is missing an attribute (evaluator-shape fallback, not a bare reference)" do
      # Deliberately narrow scope: only a *bare* {{ var }} span is
      # checked - a value going through any filter/operator/function
      # still uses the lenient path regardless of strict:, since this
      # hand-rolled evaluator's own known syntax gaps already fall back
      # to the same "undefined" sentinel for reasons unrelated to the
      # variable genuinely being undefined.
      vars = {"existing" => JSON.parse(%({"foo": "bar"}))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("Value: {{ existing.missing | default('fallback') }}", strict: true).should eq("Value: fallback")
    end

    it "does not raise under plain (non-strict) substitute - matches when:/vars-file/etc. semantics unchanged" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
      sub.substitute("Value: {{ totally_undefined_var }}").should eq("Value: undefined")
    end
  end

  # Round 812045 (pluggero.bibata_cursor): a bracket index applied to a
  # FILTER-CHAIN base (`(cmd.stdout | regex_search('...', '\\1',
  # multiline=True))[0]`) whose base resolves to Python None (regex_search
  # with no match at all - the role's own configured package wasn't a real
  # apt package, so `apt show` never printed a "Version:" line) silently
  # rendered the "undefined" sentinel and the whole play ran green, where
  # real ansible-playbook (2.19.11) hard-fails the task with
  # "Error while resolving value for '...': None has no element 0".
  # Indexing past the end of a real-but-too-short list is a DIFFERENT
  # Python error shape ("object of type 'list' has no attribute 5",
  # live-verified) and must not be collapsed into the None message (or
  # into one lenient no-op).
  describe "strict bracket-index failures (round 812045)" do
    it "raises 'None has no element 0' indexing into a no-match regex_search result" do
      vars = {"cmd_out" => JSON.parse(%({"stdout": "no version here"}))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /None has no element 0/) do
        sub.substitute(%({{ (cmd_out.stdout | regex_search('Version:\\ ([\\d\\.]{2,})', '\\1', multiline=True))[0] }}), strict: true)
      end
    end

    it "raises 'None has no element 0' indexing into a JSON-null variable, parenthesized" do
      vars = {"none_var" => JSON.parse(%(null))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /None has no element 0/) do
        sub.substitute("{{ (none_var)[0] }}", strict: true)
      end
    end

    it "raises 'None has no element 0' indexing into a JSON-null variable, plain bracket shape" do
      vars = {"none_var" => JSON.parse(%(null))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /None has no element 0/) do
        sub.substitute("{{ none_var[0] }}", strict: true)
      end
    end

    it "raises the list-out-of-range message indexing past the end of a real list" do
      vars = {"short_list" => JSON.parse(%(["a", "b"]))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /object of type 'list' has no attribute 5/) do
        sub.substitute("{{ (short_list)[5] }}", strict: true)
      end
    end

    it "raises the list-out-of-range message for the plain bracket shape too" do
      vars = {"short_list" => JSON.parse(%(["a", "b"]))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      expect_raises(Krikri::UndefinedVariableError, /object of type 'list' has no attribute 5/) do
        sub.substitute("{{ short_list[5] }}", strict: true)
      end
    end

    it "still extracts the captured group when the regex genuinely matches" do
      # This leading-paren shape delegates to Crinja internally
      # (`evaluate_leading_paren_crinja_first`), which re-encodes the
      # expression's string literals so Crinja's lexer-level escape
      # decoding (crystal-play-0.9.52+) round-trips back to the original
      # text: real ansible-playbook 2.19.11 does NOT decode string
      # escapes in inline YAML templating (live-verified - a single
      # backslash `'\1'` works as the group backreference there and a
      # doubled `'\\1'` FAILS with "NoneType' object has no attribute
      # 'group'"; the decode is .j2 template-FILE behavior only, which
      # never reaches this evaluator). A prior change asserted the
      # doubled-backslash form here instead of fixing the delegation;
      # that was the wrong behavior and this spec pins the real one.
      vars = {"cmd_out" => JSON.parse(%({"stdout": "Version: 2.11.9"}))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute(%({{ (cmd_out.stdout | regex_search('Version:\\ ([\\d\\.]{2,})', '\\1', multiline=True))[0] }}), strict: true).should eq("2.11.9")
    end

    it "keeps backslash escapes undecoded across the leading-paren Crinja delegation" do
      # Narrow for-else-of-the-bug guard, same live-verified real-Ansible
      # wording: `{{ ('x\ny' | b64encode) }}` with parens (Crinja
      # delegation) must render the backslash verbatim, exactly like
      # real ansible-playbook 2.19.11 inline ("eFxueQ==" - the b64 of
      # the 4 characters x\ny, NOT the b64 of a real newline, "eAp5").
      # Before the delegation re-encoded string literals, Crinja decoded
      # `\n` into a real newline here.
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
      sub.substitute("{{ ('x\\ny' | b64encode) }}", strict: true).should eq("eFxueQ==")
    end

    it "keeps the default() guard lenient over a None-index miss" do
      # live-verified against ansible-core 2.19.11: none_var[0] is
      # Jinja-Undefined, not an exception, so a trailing | default('x')
      # answers 'x' - only the UNGUARDED index is the hard failure.
      vars = {"none_var" => JSON.parse(%(null)), "lst" => JSON.parse(%(["a", "b"]))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("{{ (none_var)[0] | default('x') }}", strict: true).should eq("x")
      sub.substitute("{{ lst[5] | default('x') }}", strict: true).should eq("x")
    end

    it "keeps an undefined BASE lenient (real Ansible's 'x is undefined' shape, not a None-index)" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
      sub.substitute("{{ (no_such_var)[0] | default('y') }}", strict: true).should eq("y")
    end

    it "keeps a negative in-range index working" do
      vars = {"lst" => JSON.parse(%(["a", "b"]))}
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("{{ lst[-1] }}", strict: true).should eq("b")
    end
  end

  # Round 952063 (christiangda.amazon_cloudwatch_agent): the strict
  # undefined probes matched Jinja2's bare boolean/null literal spellings
  # against REGEX_BARE_VAR_REF as if they were variable NAMES, so both a
  # bare `{{ true }}` and a filter-chain `{{ true | bool }}` failed the
  # task with "'true' is undefined" where real ansible-playbook
  # (live-verified, 2.19.11) renders the literal. The role-level symptom
  # was `cwa_need_credentials: "{{ true | bool if cwa_agent_mode ==
  # 'onPremise' else cwa_use_credentials }}"` behind a bare `when:` - the
  # strict re-render of that ternary split it at the `|` and probed its
  # unselected branch's source as a variable lookup.
  describe "strict undefined probes vs Jinja literal barewords (round 952063)" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")

    it "renders a bare boolean literal in both spellings instead of raising" do
      sub.substitute("{{ true }}", strict: true).should eq("True")
      sub.substitute("{{ True }}", strict: true).should eq("True")
      sub.substitute("{{ false }}", strict: true).should eq("False")
      sub.substitute("{{ False }}", strict: true).should eq("False")
    end

    it "renders a bare null literal in both spellings instead of raising" do
      sub.substitute("{{ none }}", strict: true).should eq("")
      sub.substitute("{{ None }}", strict: true).should eq("")
    end

    it "renders a literal as a filter-chain target instead of raising" do
      sub.substitute("{{ true | bool }}", strict: true).should eq("True")
      sub.substitute("{{ false | bool }}", strict: true).should eq("False")
      sub.substitute("{{ none | bool }}", strict: true).should eq("False")
      sub.substitute("{{ True | bool }}", strict: true).should eq("True")
    end

    it "keeps a ternary with a literal-filter branch strict-renderable behind a bare when: var" do
      vars = {
        "cwa_agent_mode"       => JSON::Any.new("ec2"),
        "cwa_use_credentials"  => JSON::Any.new(false),
        "cwa_need_credentials" => JSON::Any.new(
          "{{ true | bool if cwa_agent_mode == 'onPremise' else cwa_use_credentials }}"),
      }
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
      sub.substitute("{{ cwa_need_credentials }}", strict: true).should eq("False")
    end

    it "still raises for a genuinely undefined bare variable" do
      expect_raises(Krikri::UndefinedVariableError, /'nope_literal' is undefined/) do
        sub.substitute("{{ nope_literal }}", strict: true)
      end
    end

    it "still raises for an undefined source piped into a non-tolerant filter" do
      expect_raises(Krikri::UndefinedVariableError, /'nope_literal' is undefined/) do
        sub.substitute("{{ nope_literal | bool }}", strict: true)
      end
    end
  end
end

require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# Regression table for the strict-undefined matrix (live-verified cell by
# cell against ansible-core 2.19.11 on this host): a missing attribute/key
# read on a NATIVE dict/list/scalar value raises ansible's
# "object of type 'T' has no attribute 'A'" the moment the value is
# CONSUMED - comparison operand, interpolation, filter input/argument,
# boolean coercion, ternary condition, any `is <test>` other than
# defined/undefined - in every strict templating context (module-arg
# finalization, set_fact, when:/changed_when:, loop sources, .j2
# templates), while the tolerated idioms keep working: `is defined`/
# `is undefined`, `| default(...)`, `.get(...)`, `default(omit)` flowing
# into a task arg, and a short-circuited and/or arm.
private MATRIX_VARS = JSON.parse(<<-JSON
  {
    "lst": [1, 2],
    "d": {"a": 1},
    "nested": {"a": {"b": 1}},
    "s": "str",
    "n": 5
  }
  JSON
).as_h

private def matrix_vars_hash : Hash(String, JSON::Any)
  h = Hash(String, JSON::Any).new
  MATRIX_VARS.each { |k, v| h[k] = v }
  h
end

describe "strict missing-attribute matrix (ansible-core 2.19 semantics)" do
  it "raises the attribute error when a {{ }} task arg consumes the miss, and tolerates the guarded idioms" do
    vars = matrix_vars_hash
    dict_miss = "object of type 'dict' has no attribute 'missing'"
    raising = {
      "lst.x"                                        => "object of type 'list' has no attribute 'x'",
      "d.missing"                                    => dict_miss,
      "d['missing']"                                 => dict_miss,
      "nested.a.missing"                             => dict_miss,
      "nested.missing.b"                             => dict_miss,
      "s.x"                                          => "object of type 'str' has no attribute 'x'",
      "n.x"                                          => "object of type 'int' has no attribute 'x'",
      "nope.x"                                       => "'nope' is undefined",
      "(d.missing | default({})).y"                  => "object of type 'dict' has no attribute 'y'",
      "d.missing == 'x'"                             => dict_miss,
      "d.missing != 'x'"                             => dict_miss,
      "d.missing | length"                           => dict_miss,
      "d.missing | string"                           => dict_miss,
      "d.missing in [1]"                             => dict_miss,
      "not d.missing"                                => dict_miss,
      "d.missing and true"                           => dict_miss,
      "d.missing or true"                            => dict_miss,
      "d.missing is none"                            => dict_miss,
      "d.missing | bool"                             => dict_miss,
      "d.missing | int"                              => dict_miss,
      "'latest' if d.missing == 'x' else 'present'"  => dict_miss,
      "'latest' if lst.x == 'latest' else 'present'" => "object of type 'list' has no attribute 'x'",
      "['x'] | join(d.missing)"                      => dict_miss,
    }
    raising.each do |expr, message|
      error = assert_raises(Krikri::UndefinedVariableError) do
        Krikri::VarSubstitutor.new(vars: vars).substitute("{{ #{expr} }}", strict: true)
      end
      error.message.must_equal(message)
    end

    tolerated = {
      "d.missing is defined"           => "False",
      "d.missing is undefined"         => "True",
      "d.missing | default('z')"       => "z",
      "d.missing | default('z', true)" => "z",
      "d.get('missing')"               => "",
      "d.missing | default(omit)"      => Krikri::OMIT_SENTINEL,
    }
    tolerated.each do |expr, value|
      Krikri::VarSubstitutor.new(vars: vars).substitute("{{ #{expr} }}", strict: true).must_equal(
        value, "expected {{ #{expr} }} to tolerate the miss and render #{value.inspect}")
    end

    # Short-circuit guards keep working: the is-defined arm answers False
    # and the right arm is never evaluated (live-verified vs 2.19.11).
    Krikri::VarSubstitutor.new(vars: vars).substitute(
      "{{ d.missing is defined and d.missing == 'x' }}", strict: true).must_equal("False")
    Krikri::VarSubstitutor.new(vars: vars).substitute(
      "{{ false and d.missing == 'x' }}", strict: true).must_equal("False")
  end

  it "raises/tolerates the same shapes in when:/changed_when: conditions" do
    vars = matrix_vars_hash
    dict_miss = "object of type 'dict' has no attribute 'missing'"
    raising = {
      "lst.x"                                        => "object of type 'list' has no attribute 'x'",
      "d.missing"                                    => dict_miss,
      "d['missing']"                                 => dict_miss,
      "nested.a.missing"                             => dict_miss,
      "nested.missing.b"                             => dict_miss,
      "s.x"                                          => "object of type 'str' has no attribute 'x'",
      "n.x"                                          => "object of type 'int' has no attribute 'x'",
      "nope.x"                                       => "'nope' is undefined",
      "(d.missing | default({})).y"                  => "object of type 'dict' has no attribute 'y'",
      "d.missing == 'x'"                             => dict_miss,
      "d.missing != 'x'"                             => dict_miss,
      "d.missing | length"                           => dict_miss,
      "d.missing | string"                           => dict_miss,
      "d.missing in [1]"                             => dict_miss,
      "not d.missing"                                => dict_miss,
      "d.missing and true"                           => dict_miss,
      "d.missing or true"                            => dict_miss,
      "d.missing is none"                            => dict_miss,
      "d.missing | bool"                             => dict_miss,
      "d.missing | int"                              => dict_miss,
      "'latest' if d.missing == 'x' else 'present'"  => dict_miss,
      "'latest' if lst.x == 'latest' else 'present'" => "object of type 'list' has no attribute 'x'",
    }
    raising.each do |expr, message|
      error = assert_raises(Krikri::ConditionalEvaluator::UndefinedVariableError) do
        Krikri::ConditionalEvaluator.evaluate(expr, vars, raise_undefined: true)
      end
      error.message.must_equal(message)
    end

    Krikri::ConditionalEvaluator.evaluate("d.missing is defined", vars, raise_undefined: true).must_equal(false)
    Krikri::ConditionalEvaluator.evaluate("d.missing is undefined", vars, raise_undefined: true).must_equal(true)
    # Short-circuit: the guarded second arm is never reached.
    Krikri::ConditionalEvaluator.evaluate("d.missing is defined and d.missing == 'x'", vars, raise_undefined: true).must_equal(false)

    # Non-boolean conditional results keep their own (pre-existing) error
    # class; the Omit result gets ansible's Omit-scalar message.
    [
      "d.missing | default('z')",
      "d.missing | default('z', true)",
    ].each do |expr|
      error = assert_raises(Krikri::ConditionalEvaluator::ConditionalBooleanError) do
        Krikri::ConditionalEvaluator.evaluate(expr, vars, strict: true, raise_undefined: true)
      end
      error.message.must_include("Conditionals must have a boolean result.")
    end
    error = assert_raises(Krikri::ConditionalEvaluator::ConditionalBooleanError) do
      Krikri::ConditionalEvaluator.evaluate("d.missing | default(omit)", vars, strict: true, raise_undefined: true)
    end
    error.message.must_equal("A template was resolved to an Omit scalar.")
  end

  it "raises/tolerates the same shapes in a real .j2 template render" do
    vars = matrix_vars_hash
    dict_miss = "object of type 'dict' has no attribute 'missing'"
    raising = {
      "lst.x"                                        => "object of type 'list' has no attribute 'x'",
      "d.missing"                                    => dict_miss,
      "d['missing']"                                 => dict_miss,
      "nested.a.missing"                             => dict_miss,
      "nested.missing.b"                             => dict_miss,
      "s.x"                                          => "object of type 'str' has no attribute 'x'",
      "n.x"                                          => "object of type 'int' has no attribute 'x'",
      "nope.x"                                       => "'nope' is undefined",
      "(d.missing | default({})).y"                  => "object of type 'dict' has no attribute 'y'",
      "d.missing == 'x'"                             => dict_miss,
      "d.missing != 'x'"                             => dict_miss,
      "d.missing | length"                           => dict_miss,
      "d.missing | string"                           => dict_miss,
      "d.missing in [1]"                             => dict_miss,
      "not d.missing"                                => dict_miss,
      "d.missing and true"                           => dict_miss,
      "d.missing or true"                            => dict_miss,
      "d.missing is none"                            => dict_miss,
      "d.missing | bool"                             => dict_miss,
      "d.missing | int"                              => dict_miss,
      "'latest' if d.missing == 'x' else 'present'"  => dict_miss,
      "'latest' if lst.x == 'latest' else 'present'" => "object of type 'list' has no attribute 'x'",
    }
    raising.each do |expr, message|
      Krikri::VariableSubstitutor::JinjaRenderer.strict_render_undefined_message(
        "OUT={{ #{expr} }}", vars).must_equal(
        message, "expected the template render of {{ #{expr} }} to raise #{message.inspect}")
    end

    {
      "d.missing is defined"           => "OUT=False",
      "d.missing is undefined"         => "OUT=True",
      "d.missing | default('z')"       => "OUT=z",
      "d.missing | default('z', true)" => "OUT=z",
      "d.get('missing')"               => "OUT=",
      # default(omit) is excluded here: the raw engine render emits the
      # OMIT sentinel text and the template action's own omit handling
      # strips it at the task-arg boundary (matrix cell: real renders
      # the empty string there).
    }.each do |expr, expected|
      Krikri::VariableSubstitutor::JinjaRenderer.strict_render_undefined_message(
        "{{ #{expr} }}", vars).must_equal(
        nil, "expected the template render of {{ #{expr} }} to tolerate the miss")
      # The tolerated rows render their real value through the strict
      # engine too - checked via the lenient renderer's identical output.
      Krikri::VariableSubstitutor::JinjaRenderer.new(vars).render("OUT={{ #{expr} }}").must_equal(expected)
    end
  end

  it "keeps a templated vars: value lazy: strict use raises at the use site, lenient/unused stays silent" do
    vars = matrix_vars_hash
    vars["v"] = JSON::Any.new("{{ d.missing }}")
    error = assert_raises(Krikri::UndefinedVariableError) do
      Krikri::VarSubstitutor.new(vars: vars).substitute("{{ v }}", strict: true)
    end
    error.message.must_equal("object of type 'dict' has no attribute 'missing'")
    # Lenient use renders the historical "undefined" sentinel text.
    Krikri::VarSubstitutor.new(vars: vars).substitute("{{ v }}").must_equal("undefined")
  end

  it "keeps a ternary filter argument lazy: only the SELECTED undefined branch raises" do
    # Round 2100084 (adfinis-sygroup.motd): the role's etc/motd.j2 renders
    # `{{ motd_cowsay | ternary(motd_cowsay_message.stdout, motd_message) }}`
    # where the cowsay command is SKIPPED (motd_cowsay: false), so the
    # registered result is the skip dict without `stdout`. Real Jinja2/Ansible
    # passes the undefined ARGUMENT into the filter unconsumed and only the
    # selected branch matters - verified against ansible-core 2.19.11:
    # the false-branch case renders "hello", the selected-undefined case
    # fails with the attribute error, and an undefined CONDITION (real's
    # bool() inside the filter) fails with the condition's own miss.
    vars = matrix_vars_hash
    vars["reg"] = JSON.parse(%({"changed": false, "skipped": true}))
    stdout_miss = "object of type 'dict' has no attribute 'stdout'"
    dict_miss = "object of type 'dict' has no attribute 'missing'"

    # Tolerated (live-verified: renders "hello").
    Krikri::VarSubstitutor.new(vars: vars).substitute(
      "{{ false | ternary(reg.stdout, 'hello') }}", strict: true).must_equal("hello")

    # Selected undefined branch raises at finalization (live-verified).
    {
      "true | ternary(reg.stdout, 'hi')"   => stdout_miss,
      "false | ternary('a', reg.stdout)"   => stdout_miss,
      "d.missing | ternary('a', 'b')"      => dict_miss,
      "d.missing | ternary('a', 'b', 'c')" => dict_miss,
    }.each do |expr, message|
      error = assert_raises(Krikri::UndefinedVariableError) do
        Krikri::VarSubstitutor.new(vars: vars).substitute("{{ #{expr} }}", strict: true)
      end
      error.message.must_equal(message)
    end

    # Same laziness in a real .j2 template render (the motd.j2 shape,
    # live-verified vs 2.19.11: real's template module renders the file
    # successfully on motd_cowsay false).
    Krikri::VariableSubstitutor::JinjaRenderer.strict_render_undefined_message(
      "{{ false | ternary(reg.stdout, 'hello') }}", vars).must_equal(
      nil, "expected the template render of the motd.j2 ternary to tolerate the miss")
    Krikri::VariableSubstitutor::JinjaRenderer.new(vars).render(
      "{{ false | ternary(reg.stdout, 'hello') }}").must_equal("hello")
    Krikri::VariableSubstitutor::JinjaRenderer.strict_render_undefined_message(
      "{{ true | ternary(reg.stdout, 'hi') }}", vars).must_equal(stdout_miss)
  end
end

require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_filters"

# Issue #717 (kumulustech.create_user): the role's
# `key: "{{ lookup('file', '{{ssh_key}}') }}"` had `ssh_key` undefined on
# the host. ansible-core re-renders a double-templated lookup-term constant
# under its strict-undefined environment, so the task fails with
# "Error while resolving value for 'key': 'ssh_key' is undefined"; krikri's
# lenient re-render degraded the term to '' and fed the file lookup an
# empty path, failing instead with the file plugin's own
# "Unable to access the file ''" error. The re-render must raise
# UndefinedVariableError when the term consumes an undefined value -
# but only there (a defined variable, a `| default(...)` guard, and a
# term carrying its own lookup/query call all keep the old behavior).
describe "double-templated lookup-term strict undefined (issue #717)" do
  it "raises UndefinedVariableError for an undefined variable inside the term" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)

    assert_raises_message(Krikri::UndefinedVariableError, /'ssh_key' is undefined/) do
      evaluator.evaluate(%(lookup('file', '{{ssh_key}}')))
    end
  end

  it "raises the same way through query()" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)

    assert_raises_message(Krikri::UndefinedVariableError, /'ssh_key' is undefined/) do
      evaluator.evaluate(%(query('file', '{{ssh_key}}')))
    end
  end

  it "raises the same way through the whole-span structured route (debug msg)" do
    # The whole-value `{{ lookup(...) }}` span (a debug msg's native-typed
    # route) evaluates through the krikri-jinja engine's own lookup-terms
    # re-render, not this dispatch - the engine's Undefined-kind failure
    # falls back to this evaluator's re-render, where the same probe
    # raises. whole_span_structured itself returns nil for that failure
    # (the fallback lives in its caller), so the test goes through
    # substitute(strict:) - the task-arg finalization entry - to cover
    # the whole round trip.
    substitutor = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new)

    assert_raises_message(Krikri::UndefinedVariableError, /'ssh_key' is undefined/) do
      substitutor.substitute(%( {{ lookup('file', '{{ssh_key}}') }} ), strict: true)
    end
  end

  it "still renders the term through the defined variable (file content returned)" do
    key_dir = PluginSpecHelper.tmp_path("lookup_term_strict_undefined")
    Dir.mkdir_p(key_dir)
    key_file = File.join(key_dir, "id_rsa.pub")
    File.write(key_file, "ssh-ed25519 AAAA testkey\n")

    v = Hash(String, JSON::Any).new
    v["ssh_key"] = JSON::Any.new(key_file)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('file', '{{ssh_key}}'))).must_equal("ssh-ed25519 AAAA testkey")
  end

  it "does not raise when the term's variable carries a default() guard" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)

    evaluator.evaluate(%(lookup('env', '{{never_set | default("PATH")}}')))
      .must_equal(ENV["PATH"])
  end

  it "keeps the old lenient behavior for a term that itself carries a lookup call" do
    # The strict probe would EXECUTE the inner lookup and the real render
    # below would execute it again, so the term is skipped from the probe
    # (the no-double-execute convention the other strict probes follow) -
    # an undefined var in such a term stays lenient, never raising
    # UndefinedVariableError.
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)

    result = nil
    raised = nil
    begin
      result = evaluator.evaluate(%(lookup('env', "{{ lookup('env', 'KRIKRI_NO_SUCH_VAR') }}-{{never_set}}")))
    rescue e
      raised = e
    end
    raised.must_be_nil
    (result.is_a?(String)).must_equal(true)
  end
end

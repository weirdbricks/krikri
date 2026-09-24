require "../spec_helper"
require "base64"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/jinja_filters"

# String-literal escapes inside a `when:`/`assert:` expression must decode
# (vanilla Jinja / real ansible-core condition-compiler semantics), whereas
# inline task-param `{{ }}` templating keeps them literal (real's
# AnsibleLexer doubles backslashes inline). The regression this locks: a
# method-call argument (`.split('\n')`) or a `~` concat operand resolved
# through the conditional evaluator's Crinja delegation rendered against the
# inline verbatim environment, so `'\n'` stayed a literal backslash-n and
# `.split('\n')` matched nothing / `~ '\n'` appended two characters. Found
# live via the modules_data.yml benchmark's lineinfile-staged / slurped-bytes
# asserts, both real ansible-core 2.19.11 passes. NOTE: the condition strings
# use `%q` so their `'\n'` stays a literal backslash-n (exactly what must get
# decoded at eval time); the surrounding vars are built with real newlines.
describe Krikri::ConditionalEvaluator do
  it "decodes a newline escape in a split() method-call argument" do
    vars = {
      "r" => JSON::Any.new({"stdout" => JSON::Any.new("a\nPort 1\nb\nPort 2\nc")}),
    }
    Krikri::ConditionalEvaluator.evaluate(
      %q(r.stdout.split('\n') | select('search', '^Port ') | list | length == 2),
      vars, strict: true, raise_undefined: true
    ).should be_true
  end

  it "decodes a newline escape as a concat (~) operand" do
    file_bytes = "x\ny\n" # what the slurped file actually contains
    vars = {
      "a" => JSON::Any.new({"content" => JSON::Any.new(Base64.strict_encode(file_bytes))}),
      "b" => JSON::Any.new({"stdout" => JSON::Any.new("x\ny")}),
    }
    Krikri::ConditionalEvaluator.evaluate(
      %q((a.content | b64decode) == b.stdout ~ '\n'),
      vars, strict: true, raise_undefined: true
    ).should be_true
  end
end

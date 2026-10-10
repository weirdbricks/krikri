require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# Juxtaposed `or`/`and` keyword spellings (`)or (`, `)and(`, `or("x")`).
# Real Jinja tokenizes the keywords regardless of surrounding whitespace,
# but the hand-rolled evaluator only splits on the literal " or "/" and "
# paddings, so the normalizer must give every keyword token a space on
# both sides - while never touching `or` inside an identifier
# (`approved_or_delayed`, `sort_order`) or inside a quoted literal
# (dpredhat.ansible_role_mssql's failed_when, round 5300000).
describe "Krikri::ConditionalEvaluator (conditional_boolean_keyword_spacing_test.cr)" do
  private def vars
    {
      "consent_server"      => JSON::Any.new("Y"),
      "consent_cli"         => JSON::Any.new("YES"),
      "approved_or_delayed" => JSON::Any.new(false),
      "sort_order"          => JSON::Any.new(2_i64),
      "flag"                => JSON::Any.new(true),
      "label"               => JSON::Any.new("x"),
    }
  end

  it "evaluates the mssql )or ( failed_when spacing as real does (False)" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{(consent_server != "Y" )or (consent_cli != "YES")}, vars
    ).must_equal(false)
  end

  it "stays True for )or ( when the right side really differs" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{consent_server != "Y" )or (consent_cli != "YES" }, vars
    ).must_equal(true)
  end

  it "evaluates a )and( spelling where one side matches" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{(consent_server == "Y" )and (consent_cli != "YES")}, vars
    ).must_equal(false)
  end

  it "evaluates a squeezed )and( spelling with both sides true" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{(consent_server == "Y" )and(consent_cli == "YES")}, vars
    ).must_equal(true)
  end

  it "evaluates or directly followed by a quoted string comparison" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{consent_server != "Y" or("x" == "x")}, vars
    ).must_equal(true)
  end

  it "evaluates or directly followed by a parenthesized clause" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{consent_server == "Y" or(sort_order != 2)}, vars
    ).must_equal(true)
  end

  it "keeps the False result when an or( clause is False" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{consent_server != "Y" or(sort_order == 3)}, vars
    ).must_equal(false)
  end

  it "never inserts spaces inside an identifier containing or" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{approved_or_delayed == false and sort_order == 2}, vars
    ).must_equal(true)
  end

  it "leaves a quoted or literal untouched" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{label != "skill or trait" and flag}, vars
    ).must_equal(true)
  end
end

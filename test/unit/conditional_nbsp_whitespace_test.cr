require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# A non-breaking space (U+00A0) between two tokens of a when: condition is
# ordinary whitespace to the real Jinja2 lexer (Python's str-pattern \s
# matches the whole Unicode whitespace class), so real ansible evaluates the
# condition normally - netzwirt.mysql-server's
# `when: "'mariadb' in\u00a0 mysql_server_package"` skips the task. The
# hand-rolled evaluator's whitespace normalizer used to skip such conditions
# entirely (its fast-path guard only looked for \n/\t/ASCII double spaces),
# leaving the NBSP in place: the literal " in " operator split never fired
# and the whole condition text fell through to the bare-variable fallback,
# failing the task as "'...' is undefined" (issue #884).
describe "Krikri::ConditionalEvaluator (conditional_nbsp_whitespace_test.cr)" do
  private def vars
    {
      "mysql_server_package" => JSON.parse(%q("mysql-server-5.5")),
    }
  end

  it "skips an `in` test whose operator is followed by a non-breaking space" do
    condition = "'mariadb' in\u{00A0} mysql_server_package"
    Krikri::ConditionalEvaluator.evaluate(condition, vars).must_equal(false)
  end

  it "runs an `in` test whose operator is preceded by a non-breaking space" do
    Krikri::ConditionalEvaluator.evaluate("'mariadb'\u{00A0}in mysql_server_package", vars).must_equal(false)
    Krikri::ConditionalEvaluator.evaluate("'server'\u{00A0}in mysql_server_package", vars).must_equal(true)
  end

  it "keeps a non-breaking space inside a quoted literal byte-for-byte" do
    nbsp_vars = {
      "s" => JSON.parse(%q("a\u00A0b")),
    }
    Krikri::ConditionalEvaluator.evaluate("'a\u{00A0}b' == s", nbsp_vars).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("'a b' == s", nbsp_vars).must_equal(false)
  end
end

require "../minitest_helper"
require "../../src/krikri/plugin_helpers/python_pattern"

private alias PythonPattern = Krikri::PythonPattern

describe PythonPattern do
  describe ".python_error" do
    it "returns nil for a pattern both Python and PCRE2 accept" do
      PythonPattern.python_error("^port=").must_be_nil
      PythonPattern.python_error("^(en|ja|cn)$").must_be_nil
    end

    it "words an unterminated character class the way Python's re does (issue #869: an empty-list variable templated into a regexp yields `^[]`)" do
      PythonPattern.python_error("^[]").must_equal("unterminated character set at position 1")
      # Python points at the '[' itself, not the end of the pattern.
      PythonPattern.python_error("a[b").must_equal("unterminated character set at position 1")
    end

    it "words an unclosed group the way Python's re does" do
      PythonPattern.python_error("unmatched (").must_equal("missing ), unterminated subpattern at position 10")
    end

    it "rejects extensions Python takes but PCRE2 would accept" do
      PythonPattern.python_error("(?<name>x)").must_equal("unknown extension ?<n at position 1")
    end

    it "rewrites \\uXXXX so the compiled pattern means the same thing to PCRE2" do
      PythonPattern.python_error("\\u0041").must_be_nil
    end
  end
end

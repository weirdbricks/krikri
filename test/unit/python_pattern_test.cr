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

  describe ".scan" do
    it "defuses PCRE2's top-level POSIX-class misread of '[::]' (issue #1173: zhan9san.jenkins's `regexp: '^\\s*listen       [::]:80;'`)" do
      # Python opens a plain class (members ':', ':') where PCRE2 refuses
      # the pattern outright; escaping the member char makes PCRE2 see the
      # same membership.
      scan = PythonPattern.scan("^\\s*listen       [::]:80;")
      scan.error.must_be_nil
      scan.translated.must_equal("^\\s*listen       [\\::]:80;")
      PythonPattern.python_error("^\\s*listen       [::]:80;").must_be_nil
    end

    it "defuses the same misread for the '.' and '=' leads Python also treats as literal classes" do
      PythonPattern.python_error("[.x.]").must_be_nil
      PythonPattern.python_error("[=x=]").must_be_nil
      PythonPattern.scan("[.x.]").translated.must_equal("[\\.x.]")
      PythonPattern.scan("[=x=]").translated.must_equal("[\\=x=]")
    end

    it "leaves class shapes both engines already agree on untouched" do
      # PCRE2's probe aborts at the first unescaped ']' - no misread, and
      # the two engines already parse these identically.
      {"[a:b]" => "[a:b]", "[.:]" => "[.:]", "[=:]" => "[=:]",
       "[:a]b:]" => "[:a]b:]", "[:a[b]:]" => "[:a[b]:]",
       "[:]" => "[:]", "[[:alpha:]]" => "[[:alpha:]]"}.each do |raw, translated|
        scan = PythonPattern.scan(raw)
        scan.error.must_be_nil
        scan.translated.must_equal(translated)
      end
    end

    it "maps a later PCRE2 error position back through the class rewrite" do
      # '[:x:])' compiles the class but stumbles on the stray ')'; the
      # reported position is the source ')' (4), not the translated one
      # (6, two chars later after the inserted backslash).
      PythonPattern.python_error("[:x:])").must_equal("unbalanced parenthesis at position 4")
    end
  end
end

require "../minitest_helper"
require "../../src/krikri/difflib"

# Krikri::Difflib is a port of Python's difflib.SequenceMatcher and
# unified_diff, which is what ansible's callback renders `--diff` bodies
# with (ansible/plugins/callback/__init__.py, `_get_diff`). Every expected
# value below was produced by running the same input through CPython's
# difflib; that matters because GNU diff - the tool this replaced - chooses
# different matching blocks for some inputs and so lays the SAME before/
# after content out differently (issue #736: martin-micimo.haproxy's
# haproxy.cfg rendered a 2400 B body against ansible's 2394 B).
describe "Krikri::Difflib" do
  it "lays out a hunk the way difflib does where GNU diff picks another matching block" do
    # `diff -u` finds the leading l0 of the AFTER side as the anchor and
    # puts the insert first; difflib anchors on the common l0/l1 run and
    # puts the insert after the first context line. Only difflib's ordering
    # matches ansible's stdout.
    lines = Krikri::Difflib.unified_diff(["l0\n", "l1\n", "l1\n"], ["l0\n", "l0\n", "l1\n", "l0\n"])
    lines.must_equal([
      "--- \n",
      "+++ \n",
      "@@ -1,3 +1,4 @@\n",
      "+l0\n",
      " l0\n",
      " l1\n",
      "-l1\n",
      "+l0\n",
    ])
  end

  it "splits lines on Python's splitlines boundaries and keeps the terminators" do
    Krikri::Difflib.splitlines("").must_equal([] of String)
    Krikri::Difflib.splitlines("a\r\nb\r\n").must_equal(["a\r\n", "b\r\n"])
    Krikri::Difflib.splitlines("a\rb").must_equal(["a\r", "b"])
    Krikri::Difflib.splitlines("a\u000bb\u000c").must_equal(["a\u000b", "b\u000c"])
    Krikri::Difflib.splitlines("a\n\nb").must_equal(["a\n", "\n", "b"])
  end

  it "folds ansible's no-newline note into the last line of a side that lacks it" do
    lines = Krikri::Difflib.unified_diff(
      Krikri::Difflib.match_lines("a\nb"),
      Krikri::Difflib.match_lines("a\nc\n"))
    lines[2..].must_equal([
      "@@ -1,2 +1,2 @@\n",
      " a\n",
      "-b\n\\ No newline at end of file\n",
      "+c\n",
    ])
  end

  it "groups distant changes into separate hunks with three lines of context" do
    before = (1..12).map { |i| "l#{i}\n" }
    after = before.dup
    after[1] = "changed2\n"
    after[9] = "changed10\n"
    Krikri::Difflib.unified_diff(before, after)[2..].must_equal([
      "@@ -1,5 +1,5 @@\n",
      " l1\n",
      "-l2\n",
      "+changed2\n",
      " l3\n",
      " l4\n",
      " l5\n",
      "@@ -7,6 +7,6 @@\n",
      " l7\n",
      " l8\n",
      " l9\n",
      "-l10\n",
      "+changed10\n",
      " l11\n",
      " l12\n",
    ])
  end

  it "stops anchoring on a line repeated past difflib's autojunk limit at 200 elements" do
    # Below the threshold a line repeated 197 times is still an anchor, so
    # the matcher reports an inserted block moved front-to-back. At 201
    # elements "a" repeats more than 201//100 + 1 times, difflib's autojunk
    # purge drops it from the index entirely and the same pair becomes a
    # wholesale rewrite - which is what ansible prints.
    small_before = Array.new(197, "a\n") + ["b\n", "c\n"]
    small_after = ["b\n", "c\n"] + Array.new(197, "a\n")
    Krikri::Difflib.unified_diff(small_before, small_after).size.must_equal(14)

    before = Array.new(199, "a\n") + ["b\n", "c\n"]
    after = ["b\n", "c\n"] + Array.new(199, "a\n")
    lines = Krikri::Difflib.unified_diff(before, after)
    lines.size.must_equal(403)
    lines[2].must_equal("@@ -1,201 +1,201 @@\n")
    lines[3].must_equal("-a\n")
    lines[202].must_equal(" b\n")
    lines[203].must_equal(" c\n")
    lines[204].must_equal("+a\n")
  end
end

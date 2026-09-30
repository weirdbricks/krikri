require "../minitest_helper"
require "../../src/krikri/py_set"
require "../../src/krikri/variable_substitutor"

# Expected orders come from CPython 3.13: list(set(a) | set(b)), list(set(a) & set(b)),
# list(set(a) - set(b)) - the exact lists real ansible's union/intersect/difference filters
# return for integer inputs (string sets are hash-randomized per process and not covered).
private def check(a : Array(Int64), b : Array(Int64), union : Array(Int64), inter : Array(Int64), diff : Array(Int64))
  Krikri::PySet.union(a, b).must_equal(union)
  Krikri::PySet.intersect(a, b).must_equal(inter)
  Krikri::PySet.difference(a, b).must_equal(diff)
end

describe Krikri::PySet do
  it "reproduces CPython's integer set iteration order for union/intersect/difference" do
    check([3, 1, 2, 9, 17] of Int64, [2, 5, 4, 25, 1] of Int64,
          [1, 2, 3, 4, 5, 9, 17, 25] of Int64,
          [1, 2] of Int64,
          [9, 3, 17] of Int64)
    check([3, 1, 2] of Int64, [2, 5, 4] of Int64,
          [1, 2, 3, 4, 5] of Int64,
          [2] of Int64,
          [1, 3] of Int64)
    check([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39] of Int64, [30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59] of Int64,
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59] of Int64,
          [32, 33, 34, 35, 36, 37, 38, 39, 30, 31] of Int64,
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29] of Int64)
    check([-1, -2, 0, 5] of Int64, [-5, 3, 0] of Int64,
          [0, 3, 5, -2, -5, -1] of Int64,
          [0] of Int64,
          [5, -1, -2] of Int64)
    check([100, 200, 300, 400, 500, 600, 700] of Int64, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] of Int64,
          [1, 2, 3, 4, 5, 6, 7, 200, 8, 9, 10, 400, 600, 100, 300, 500, 700] of Int64,
          [] of Int64,
          [100, 200, 300, 400, 500, 600, 700] of Int64)
    check([9, 8, 7, 6, 5, 4, 3, 2, 1] of Int64, [1, 3, 5, 7, 9, 11] of Int64,
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 11] of Int64,
          [1, 3, 5, 7, 9] of Int64,
          [8, 2, 4, 6] of Int64)
    check([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39] of Int64, [3, 5] of Int64,
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39] of Int64,
          [3, 5] of Int64,
          [0, 1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39] of Int64)
  end

  it "hashes negative ints like CPython (-1 -> -2, sign kept)" do
    Krikri::PySet.py_hash(-1_i64).must_equal((-2_i64).to_u64!)
    Krikri::PySet.py_hash(5_i64).must_equal(5_u64)
  end

  # CPython builds `set(a) ^ set(b)` as a copy of set(b) with every member of
  # set(a) either tombstoned (when it is also in b) or inserted into it - the
  # tombstoned slots stay occupied for probing and a later insert can reuse
  # them, which is what makes the resulting order its own (it is not any of
  # the other three operations' orders). The next two cases were picked from a
  # 3200-pair randomized cross-check against real CPython 3.13 because they
  # both hit that dummy-slot reuse, the second one also resizing mid-update.
  it "reproduces CPython's symmetric_difference order, tombstones included" do
    Krikri::PySet.symmetric_difference([3, 1, 2] of Int64, [2, 5, 4] of Int64)
      .must_equal([1, 3, 4, 5] of Int64)
    Krikri::PySet.symmetric_difference([] of Int64, [1, 2] of Int64)
      .must_equal([1, 2] of Int64)
    Krikri::PySet.symmetric_difference([2_i64 ** 62, -1, 0] of Int64, [-1, 5] of Int64)
      .must_equal([0, 2_i64 ** 62, 5] of Int64)
    Krikri::PySet.symmetric_difference([-2, 30, -11, -1] of Int64, [-1, -1] of Int64)
      .must_equal([-11, -2, 30] of Int64)
    Krikri::PySet.symmetric_difference(
      [-1, -2, -2, -2, -2, -2, 2, -2, 1, -1, -1, 2, 2, 2, 1, -2, 1] of Int64,
      [15, -12, 8, -26, -1, 14, 28, 21] of Int64
    ).must_equal([1, 2, -26, 8, 14, 15, -12, 21, 28, -2] of Int64)
    Krikri::PySet.symmetric_difference(
      [17, 14, 4, 15, 0, 0, 0, 12, 19, 15] of Int64,
      [1, 5, 4, 1, 1] of Int64
    ).must_equal([0, 1, 5, 12, 14, 15, 17, 19] of Int64)
    Krikri::PySet.symmetric_difference(
      [4, 20, -23, -11, -1, 11, -15, 18, 18, 25, -10, -25, -28, 26, 18, 0] of Int64,
      [5, 2, 6, 6, 4, 5, 1, 2] of Int64
    ).must_equal([0, 1, 2, 5, 6, 11, 18, 20, 25, 26, -28, -25, -23, -15, -11, -10, -1] of Int64)
  end
end

describe "query()/lookup() list results in mixed text" do
  it "renders list-forcing lookups as Python repr, like real Ansible" do
    r = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")
    r.substitute("{{ query('items', [1,2]) }} x", output: true).must_equal("[1, 2] x")
    r.substitute("{{ q('list', 'a', 1) }} y", output: true).must_equal("['a', 1] y")
    r.substitute("{{ lookup('items', [1,2], wantlist=True) }} z", output: true).must_equal("[1, 2] z")
  end

  it "leaves a scalar lookup that merely looks like JSON untouched" do
    path = File.tempname("jsonish", ".txt")
    File.write(path, "[1,2]")
    begin
      r = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")
      r.substitute("{{ lookup('file', '#{path}') }} f", output: true).must_equal("[1,2] f")
    ensure
      File.delete(path)
    end
  end
end

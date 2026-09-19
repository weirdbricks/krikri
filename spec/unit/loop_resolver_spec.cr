require "../spec_helper"
require "../../src/krikri/loop_resolver"

private def s(str : String) : JSON::Any
  JSON::Any.new(str)
end

describe Krikri::LoopResolver do
  describe ".with_dict" do
    it "turns a hash into key/value item objects" do
      hash = {"a" => s("1"), "b" => s("2")}
      items = Krikri::LoopResolver.with_dict(hash)

      items.size.should eq(2)
      items.map(&.["key"].as_s).should eq(["a", "b"])
      items.map(&.["value"].as_s).should eq(["1", "2"])
    end
  end

  describe ".with_nested" do
    it "computes the cartesian product with the first list varying slowest" do
      items = Krikri::LoopResolver.with_nested([[s("a"), s("b")], [s("x"), s("y")]])

      items.map(&.as_a.map(&.as_s)).should eq([
        ["a", "x"], ["a", "y"], ["b", "x"], ["b", "y"],
      ])
    end

    it "handles a single list (degenerate case)" do
      items = Krikri::LoopResolver.with_nested([[s("a"), s("b")]])
      items.map(&.as_a.map(&.as_s)).should eq([["a"], ["b"]])
    end
  end

  describe ".with_together" do
    it "zips lists elementwise with the first list's elements first" do
      items = Krikri::LoopResolver.with_together([[s("a"), s("b")], [s("x"), s("y")]])

      items.map(&.as_a.map(&.as_s)).should eq([
        ["a", "x"], ["b", "y"],
      ])
    end

    it "null-pads shorter lists (real Ansible's zip_longest semantics)" do
      # Real Ansible's with_together: runs itertools.zip_longest over the
      # sources, padding every shorter list with None - a with_together:
      # over a 3-element and a 2-element list must still iterate 3 times,
      # with item.1 null (not the empty/undefined sentinel) on the third.
      items = Krikri::LoopResolver.with_together([[s("a"), s("b"), s("c")], [s("x")]])

      items.size.should eq(3)
      items[2].as_a.size.should eq(2)
      items[2].as_a[0].as_s.should eq("c")
      items[2].as_a[1].raw.nil?.should be_true
    end

    it "yields zero items when all lists are empty" do
      items = Krikri::LoopResolver.with_together([[] of JSON::Any, [] of JSON::Any])
      items.size.should eq(0)
    end
  end

  describe ".with_indexed_items" do
    it "pairs each item with its stringified index" do
      items = Krikri::LoopResolver.with_indexed_items([s("x"), s("y"), s("z")])

      items.map(&.as_a.map(&.as_s)).should eq([
        ["0", "x"], ["1", "y"], ["2", "z"],
      ])
    end
  end

  describe ".with_sequence" do
    it "expands a bare count into 1..n" do
      values = Krikri::LoopResolver.with_sequence("5").map(&.as_s)
      values.should eq(["1", "2", "3", "4", "5"])
    end

    it "honors start= and end=" do
      values = Krikri::LoopResolver.with_sequence("start=2 end=6").map(&.as_s)
      values.should eq(["2", "3", "4", "5", "6"])
    end

    it "honors stride=" do
      values = Krikri::LoopResolver.with_sequence("start=0 end=10 stride=5").map(&.as_s)
      values.should eq(["0", "5", "10"])
    end

    it "honors count= as an alternative to end=" do
      values = Krikri::LoopResolver.with_sequence("start=1 count=3 stride=2").map(&.as_s)
      values.should eq(["1", "3", "5"])
    end

    it "counts down when end is before start" do
      values = Krikri::LoopResolver.with_sequence("start=3 end=1").map(&.as_s)
      values.should eq(["3", "2", "1"])
    end

    it "applies a custom format string" do
      values = Krikri::LoopResolver.with_sequence("start=1 end=3 format=host%02d").map(&.as_s)
      values.should eq(["host01", "host02", "host03"])
    end
  end
end

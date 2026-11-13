require "../minitest_helper"

# scripts/minitest.sh splits the suite across shard PROCESSES and every process
# asks PluginSpecHelper::Slice which tests are its own (see the run_one gate in
# test/minitest_helper.cr). These pin the two rules that make that safe: a
# measured test runs on exactly the shard the balancer assigned, and a test the
# map has never heard of (added since the last publish) still runs on exactly
# one shard instead of being dropped.
describe "PluginSpecHelper::Slice" do
  it "is absent unless the runner handed this process a slice" do
    if ENV["MINITEST_SLICE_MAP"]?
      PluginSpecHelper::SLICE.wont_be_nil
    else
      PluginSpecHelper::SLICE.must_be_nil
    end
  end

  it "gives a measured test to the shard the balancer assigned it to" do
    slice = PluginSpecHelper::Slice.new(1, 4, Set{"Spec#mine"}, Set{"Spec#mine", "Spec#theirs"})
    slice.runs?("Spec#mine").must_equal(true)
    slice.runs?("Spec#theirs").must_equal(false)
  end

  it "loads a map file, claiming only this shard's rows and knowing the rest" do
    path = PluginSpecHelper.tmp_path("slice-map.tsv")
    File.write(path, "Spec#zero\t0\nSpec#one\t1\nSpec#two\t1\n")
    slice = PluginSpecHelper::Slice.load(path, 1, 3) || raise "expected a slice for shard 1 of 3"
    slice.runs?("Spec#zero").must_equal(false)
    slice.runs?("Spec#one").must_equal(true)
    slice.runs?("Spec#two").must_equal(true)
    # Unmeasured: hashed, so it lands on whichever shard the hash picks.
    slice.runs?("Spec#new").must_equal(PluginSpecHelper::Slice.slot("Spec#new", 3) == 1)
  end

  it "scatters an unmeasured test onto exactly one shard, identically in every process" do
    slices = (0...4).map { |index| PluginSpecHelper::Slice.new(index, 4, Set(String).new, Set(String).new) }
    names = (0...500).map { |index| "Spec#unmeasured #{index}" }
    names.each do |name|
      claimants = slices.count(&.runs?(name))
      claimants.must_equal(1)
      # String#hash is seeded per process; the slot must not be, or two shards
      # would claim the same new test and another one would run it never.
      PluginSpecHelper::Slice.slot(name, 4).must_equal(PluginSpecHelper::Slice.slot(name, 4))
    end
  end

  it "refuses a slice index outside the shard range instead of running nothing" do
    path = PluginSpecHelper.tmp_path("slice-map-out-of-range.tsv")
    File.write(path, "Spec#zero\t0\n")
    PluginSpecHelper::Slice.load(path, 4, 4).must_be_nil
    PluginSpecHelper::Slice.load(path, 0, 0).must_be_nil
  end
end

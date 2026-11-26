describe "divergence corpus" do
  it "replays 1869-deferred-loop-when-item-undefined" do
    expected, actual, report = divergence_transcripts(1869, "deferred-loop-when-item-undefined")
    assert_equal(expected, actual, report)
  end
end

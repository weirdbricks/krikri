describe "divergence corpus" do
  it "replays 1703-block-delegated-children-dropped" do
    expected, actual, report = divergence_transcripts(1703, "block-delegated-children-dropped")
    assert_equal(expected, actual, report)
  end
end

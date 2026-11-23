describe "divergence corpus" do
  it "replays 1703-block-rescue-runs-before-unreachable" do
    expected, actual, report = divergence_transcripts(1703, "block-rescue-runs-before-unreachable")
    assert_equal(expected, actual, report)
  end
end

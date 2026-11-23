describe "divergence corpus" do
  it "replays 1703-rescue-unreachable-with-block-ignore-errors" do
    expected, actual, report = divergence_transcripts(1703, "rescue-unreachable-with-block-ignore-errors")
    assert_equal(expected, actual, report)
  end
end

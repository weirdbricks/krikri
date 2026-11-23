describe "divergence corpus" do
  it "replays 1703-unreachable-skips-block-rescue-and-always" do
    expected, actual, report = divergence_transcripts(1703, "unreachable-skips-block-rescue-and-always")
    assert_equal(expected, actual, report)
  end
end

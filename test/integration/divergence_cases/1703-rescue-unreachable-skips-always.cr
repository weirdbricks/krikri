describe "divergence corpus" do
  it "replays 1703-rescue-unreachable-skips-always" do
    expected, actual, report = divergence_transcripts(1703, "rescue-unreachable-skips-always")
    assert_equal(expected, actual, report)
  end
end

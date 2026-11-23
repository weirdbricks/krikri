describe "divergence corpus" do
  it "replays 1703-multi-host-block-rescue" do
    expected, actual, report = divergence_transcripts(1703, "multi-host-block-rescue")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1703-pre-upload-unreachable-booked-at-block" do
    expected, actual, report = divergence_transcripts(1703, "pre-upload-unreachable-booked-at-block")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1863-unarchive-no-log-error-block" do
    expected, actual, report = divergence_transcripts(1863, "unarchive-no-log-error-block")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1707-when-error-fails-once" do
    expected, actual, report = divergence_transcripts(1707, "when-error-fails-once")
    assert_equal(expected, actual, report)
  end
end

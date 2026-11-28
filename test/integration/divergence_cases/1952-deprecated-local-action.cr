describe "divergence corpus" do
  it "replays 1952-deprecated-local-action" do
    expected, actual, report = divergence_transcripts(1952, "deprecated-local-action")
    assert_equal(expected, actual, report)
  end
end

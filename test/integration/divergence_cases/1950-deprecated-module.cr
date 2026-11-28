describe "divergence corpus" do
  it "replays 1950-deprecated-module" do
    expected, actual, report = divergence_transcripts(1950, "deprecated-module")
    assert_equal(expected, actual, report)
  end
end

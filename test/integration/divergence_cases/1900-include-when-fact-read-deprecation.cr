describe "divergence corpus" do
  it "replays 1900-include-when-fact-read-deprecation" do
    expected, actual, report = divergence_transcripts(1900, "include-when-fact-read-deprecation")
    assert_equal(expected, actual, report)
  end
end

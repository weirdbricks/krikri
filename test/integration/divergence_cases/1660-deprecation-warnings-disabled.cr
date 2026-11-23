describe "divergence corpus" do
  it "replays 1660-deprecation-warnings-disabled" do
    expected, actual, report = divergence_transcripts(1660, "deprecation-warnings-disabled")
    assert_equal(expected, actual, report)
  end
end

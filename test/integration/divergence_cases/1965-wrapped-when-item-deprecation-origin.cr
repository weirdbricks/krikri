describe "divergence corpus" do
  it "replays 1965-wrapped-when-item-deprecation-origin" do
    expected, actual, report = divergence_transcripts(1965, "wrapped-when-item-deprecation-origin")
    assert_equal(expected, actual, report)
  end
end

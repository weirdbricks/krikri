describe "divergence corpus" do
  it "replays 1967-dotstrap-sensible-when-unknown-filter" do
    expected, actual, report = divergence_transcripts(1967, "dotstrap-sensible-when-unknown-filter")
    assert_equal(expected, actual, report)
  end
end

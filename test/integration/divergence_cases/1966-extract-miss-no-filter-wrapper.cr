describe "divergence corpus" do
  it "replays 1966-extract-miss-no-filter-wrapper" do
    expected, actual, report = divergence_transcripts(1966, "extract-miss-no-filter-wrapper")
    assert_equal(expected, actual, report)
  end
end

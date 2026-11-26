describe "divergence corpus" do
  it "replays 1870-fnxone-baseline-drift-touch-check" do
    expected, actual, report = divergence_transcripts(1870, "fnxone-baseline-drift-touch-check")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1657-strategy-plugin-retry-fallback" do
    expected, actual, report = divergence_transcripts(1657, "strategy-plugin-retry-fallback")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1773-anthony25-letsencrypt-check-loop-deprecation" do
    expected, actual, report = divergence_transcripts(1773, "anthony25-letsencrypt-check-loop-deprecation")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1770-publicarray-unbound-debug-var-fact-deprecation" do
    expected, actual, report = divergence_transcripts(1770, "publicarray-unbound-debug-var-fact-deprecation")
    assert_equal(expected, actual, report)
  end
end

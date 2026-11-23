describe "divergence corpus" do
  it "replays 1616-wabumike-k3s-check-set-fact-parenthesized-filter" do
    expected, actual, report = divergence_transcripts(1616, "wabumike-k3s-check-set-fact-parenthesized-filter")
    assert_equal(expected, actual, report)
  end
end

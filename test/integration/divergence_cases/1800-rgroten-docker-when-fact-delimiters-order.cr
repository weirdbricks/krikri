describe "divergence corpus" do
  it "replays 1800-rgroten-docker-when-fact-delimiters-order" do
    expected, actual, report = divergence_transcripts(1800, "rgroten-docker-when-fact-delimiters-order")
    assert_equal(expected, actual, report)
  end
end

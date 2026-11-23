describe "divergence corpus" do
  it "replays 1744-tansudasli-gcp-instances-check" do
    expected, actual, report = divergence_transcripts(1744, "tansudasli-gcp-instances-check")
    assert_equal(expected, actual, report)
  end
end

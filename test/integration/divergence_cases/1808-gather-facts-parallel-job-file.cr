describe "divergence corpus" do
  it "replays 1808-gather-facts-parallel-job-file" do
    expected, actual, report = divergence_transcripts(1808, "gather-facts-parallel-job-file")
    assert_equal(expected, actual, report)
  end
end

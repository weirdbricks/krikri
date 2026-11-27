describe "divergence corpus" do
  it "replays 1899-async-poll0-budget-kills-job" do
    expected, actual, report = divergence_transcripts(1899, "async-poll0-budget-kills-job")
    assert_equal(expected, actual, report)
  end
end

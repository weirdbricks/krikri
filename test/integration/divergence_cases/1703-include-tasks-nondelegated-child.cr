describe "divergence corpus" do
  it "replays 1703-include-tasks-nondelegated-child" do
    expected, actual, report = divergence_transcripts(1703, "include-tasks-nondelegated-child")
    assert_equal(expected, actual, report)
  end
end

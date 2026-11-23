describe "divergence corpus" do
  it "replays 1688-delegated-loop-unreachable-msg-host" do
    expected, actual, report = divergence_transcripts(1688, "delegated-loop-unreachable-msg-host")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1681-delegated-unreachable-msg-host" do
    expected, actual, report = divergence_transcripts(1681, "delegated-unreachable-msg-host")
    assert_equal(expected, actual, report)
  end
end

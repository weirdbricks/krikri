describe "divergence corpus" do
  it "replays 1687-handler-remote-module-before-delegated-task" do
    expected, actual, report = divergence_transcripts(1687, "handler-remote-module-before-delegated-task")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1706-controller-task-before-unreachable" do
    expected, actual, report = divergence_transcripts(1706, "controller-task-before-unreachable")
    assert_equal(expected, actual, report)
  end
end

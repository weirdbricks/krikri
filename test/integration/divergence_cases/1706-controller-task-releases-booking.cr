describe "divergence corpus" do
  it "replays 1706-controller-task-releases-booking" do
    expected, actual, report = divergence_transcripts(1706, "controller-task-releases-booking")
    assert_equal(expected, actual, report)
  end
end

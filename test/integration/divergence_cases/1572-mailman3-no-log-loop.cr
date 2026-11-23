describe "divergence corpus" do
  it "replays 1572-mailman3-no-log-loop" do
    expected, actual, report = divergence_transcripts(1572, "mailman3-no-log-loop")
    assert_equal(expected, actual, report)
  end
end

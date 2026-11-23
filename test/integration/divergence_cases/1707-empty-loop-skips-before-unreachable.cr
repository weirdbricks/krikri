describe "divergence corpus" do
  it "replays 1707-empty-loop-skips-before-unreachable" do
    expected, actual, report = divergence_transcripts(1707, "empty-loop-skips-before-unreachable")
    assert_equal(expected, actual, report)
  end
end

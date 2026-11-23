describe "divergence corpus" do
  it "replays 1745-loop-when-per-item" do
    expected, actual, report = divergence_transcripts(1745, "loop-when-per-item")
    assert_equal(expected, actual, report)
  end
end

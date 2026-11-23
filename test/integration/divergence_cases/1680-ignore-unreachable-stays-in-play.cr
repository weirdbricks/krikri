describe "divergence corpus" do
  it "replays 1680-ignore-unreachable-stays-in-play" do
    expected, actual, report = divergence_transcripts(1680, "ignore-unreachable-stays-in-play")
    assert_equal(expected, actual, report)
  end
end

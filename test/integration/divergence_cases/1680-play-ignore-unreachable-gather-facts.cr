describe "divergence corpus" do
  it "replays 1680-play-ignore-unreachable-gather-facts" do
    expected, actual, report = divergence_transcripts(1680, "play-ignore-unreachable-gather-facts")
    assert_equal(expected, actual, report)
  end
end

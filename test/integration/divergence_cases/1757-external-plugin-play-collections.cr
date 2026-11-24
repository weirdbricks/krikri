describe "divergence corpus" do
  it "replays 1757-external-plugin-play-collections" do
    expected, actual, report = divergence_transcripts(1757, "external-plugin-play-collections")
    assert_equal(expected, actual, report)
  end
end

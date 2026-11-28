describe "divergence corpus" do
  it "replays 1958-avoid-implicit-copy-content" do
    expected, actual, report = divergence_transcripts(1958, "avoid-implicit-copy-content")
    assert_equal(expected, actual, report)
  end
end

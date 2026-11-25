describe "divergence corpus" do
  it "replays 1819-ben-le-awx-nginx-later-read" do
    expected, actual, report = divergence_transcripts(1819, "ben-le-awx-nginx-later-read")
    assert_equal(expected, actual, report)
  end
end

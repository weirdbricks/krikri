describe "divergence corpus" do
  it "replays 1863-uri-gzip-content-length" do
    expected, actual, report = divergence_transcripts(1863, "uri-gzip-content-length")
    assert_equal(expected, actual, report)
  end
end

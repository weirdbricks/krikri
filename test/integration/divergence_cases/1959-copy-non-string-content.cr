describe "divergence corpus" do
  it "replays 1959-copy-non-string-content" do
    expected, actual, report = divergence_transcripts(1959, "copy-non-string-content")
    assert_equal(expected, actual, report)
  end
end

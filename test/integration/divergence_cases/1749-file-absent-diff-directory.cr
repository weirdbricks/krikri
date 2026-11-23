describe "divergence corpus" do
  it "replays 1749-file-absent-diff-directory" do
    expected, actual, report = divergence_transcripts(1749, "file-absent-diff-directory")
    assert_equal(expected, actual, report)
  end
end

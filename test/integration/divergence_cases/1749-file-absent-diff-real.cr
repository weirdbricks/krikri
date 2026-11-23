describe "divergence corpus" do
  it "replays 1749-file-absent-diff-real" do
    expected, actual, report = divergence_transcripts(1749, "file-absent-diff-real")
    assert_equal(expected, actual, report)
  end
end

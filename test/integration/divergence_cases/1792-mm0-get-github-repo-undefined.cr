describe "divergence corpus" do
  it "replays 1792-mm0-get-github-repo-undefined" do
    expected, actual, report = divergence_transcripts(1792, "mm0-get-github-repo-undefined")
    assert_equal(expected, actual, report)
  end
end

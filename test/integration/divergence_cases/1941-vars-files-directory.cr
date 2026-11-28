describe "divergence corpus" do
  it "replays 1941-vars-files-directory" do
    expected, actual, report = divergence_transcripts(1941, "vars-files-directory")
    assert_equal(expected, actual, report)
  end
end

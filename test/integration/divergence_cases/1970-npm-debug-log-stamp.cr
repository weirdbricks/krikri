describe "divergence corpus" do
  it "replays 1970-npm-debug-log-stamp" do
    expected, actual, report = divergence_transcripts(1970, "npm-debug-log-stamp")
    assert_equal(expected, actual, report)
  end
end

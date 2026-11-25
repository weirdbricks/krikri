describe "divergence corpus" do
  it "replays 1834-local-command-ps1" do
    expected, actual, report = divergence_transcripts(1834, "local-command-ps1")
    assert_equal(expected, actual, report)
  end
end

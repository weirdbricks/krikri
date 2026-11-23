describe "divergence corpus" do
  it "replays 1646-command-with-missing-interpreter" do
    expected, actual, report = divergence_transcripts(1646, "command-with-missing-interpreter")
    assert_equal(expected, actual, report)
  end
end

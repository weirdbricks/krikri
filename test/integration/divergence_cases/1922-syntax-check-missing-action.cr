describe "divergence corpus" do
  it "replays 1922-syntax-check-missing-action" do
    expected, actual, report = divergence_transcripts(1922, "syntax-check-missing-action")
    assert_equal(expected, actual, report)
  end
end

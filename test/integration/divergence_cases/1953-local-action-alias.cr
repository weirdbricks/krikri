describe "divergence corpus" do
  it "replays 1953-local-action-alias" do
    expected, actual, report = divergence_transcripts(1953, "local-action-alias")
    assert_equal(expected, actual, report)
  end
end

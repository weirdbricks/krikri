describe "divergence corpus" do
  it "replays 1980-argspec-bigint-messages" do
    expected, actual, report = divergence_transcripts(1980, "argspec-bigint-messages")
    assert_equal(expected, actual, report)
  end
end

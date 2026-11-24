describe "divergence corpus" do
  it "replays 1728-ddilts-change-password-raw-apt" do
    expected, actual, report = divergence_transcripts(1728, "ddilts-change-password-raw-apt")
    assert_equal(expected, actual, report)
  end
end

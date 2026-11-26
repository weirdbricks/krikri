describe "divergence corpus" do
  it "replays 1849-totaldebug-users-getent-null-key" do
    expected, actual, report = divergence_transcripts(1849, "totaldebug-users-getent-null-key")
    assert_equal(expected, actual, report)
  end
end

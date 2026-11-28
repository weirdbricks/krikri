describe "divergence corpus" do
  it "replays 1962-mysql-connect-failure-message" do
    expected, actual, report = divergence_transcripts(1962, "mysql-connect-failure-message")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1961-mysql-connect-timeout" do
    expected, actual, report = divergence_transcripts(1961, "mysql-connect-timeout")
    assert_equal(expected, actual, report)
  end
end

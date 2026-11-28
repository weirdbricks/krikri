describe "divergence corpus" do
  it "replays 1975-mysql-connect-timeout-bigint" do
    expected, actual, report = divergence_transcripts(1975, "mysql-connect-timeout-bigint")
    assert_equal(expected, actual, report)
  end
end

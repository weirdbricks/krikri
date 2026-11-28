describe "divergence corpus" do
  it "replays 1975-mysql-db-login-port-range" do
    expected, actual, report = divergence_transcripts(1975, "mysql-db-login-port-range")
    assert_equal(expected, actual, report)
  end
end

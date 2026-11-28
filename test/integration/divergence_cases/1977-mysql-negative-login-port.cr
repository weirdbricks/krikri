describe "divergence corpus" do
  it "replays 1977-mysql-negative-login-port" do
    expected, actual, report = divergence_transcripts(1977, "mysql-negative-login-port")
    assert_equal(expected, actual, report)
  end
end

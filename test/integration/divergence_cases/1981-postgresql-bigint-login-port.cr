describe "divergence corpus" do
  it "replays 1981-postgresql-bigint-login-port" do
    expected, actual, report = divergence_transcripts(1981, "postgresql-bigint-login-port")
    assert_equal(expected, actual, report)
  end
end

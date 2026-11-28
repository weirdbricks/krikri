describe "divergence corpus" do
  it "replays 1979-argspec-bigint-login-port" do
    expected, actual, report = divergence_transcripts(1979, "argspec-bigint-login-port")
    assert_equal(expected, actual, report)
  end
end

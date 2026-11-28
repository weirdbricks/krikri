describe "divergence corpus" do
  it "replays 1978-argspec-integral-float-login-port" do
    expected, actual, report = divergence_transcripts(1978, "argspec-integral-float-login-port")
    assert_equal(expected, actual, report)
  end
end

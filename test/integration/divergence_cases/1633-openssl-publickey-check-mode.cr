describe "divergence corpus" do
  it "replays 1633-openssl-publickey-check-mode" do
    expected, actual, report = divergence_transcripts(1633, "openssl-publickey-check-mode")
    assert_equal(expected, actual, report)
  end
end

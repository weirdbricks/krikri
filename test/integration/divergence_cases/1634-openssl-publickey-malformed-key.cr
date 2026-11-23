describe "divergence corpus" do
  it "replays 1634-openssl-publickey-malformed-key" do
    expected, actual, report = divergence_transcripts(1634, "openssl-publickey-malformed-key")
    assert_equal(expected, actual, report)
  end
end

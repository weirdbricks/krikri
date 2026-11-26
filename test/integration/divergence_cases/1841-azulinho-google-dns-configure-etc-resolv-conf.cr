describe "divergence corpus" do
  it "replays 1841-azulinho-google-dns-configure-etc-resolv-conf" do
    expected, actual, report = divergence_transcripts(1841, "azulinho-google-dns-configure-etc-resolv-conf")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1833-openssl-csr-crl-distribution-points-required-one-of" do
    expected, actual, report = divergence_transcripts(1833, "openssl-csr-crl-distribution-points-required-one-of")
    assert_equal(expected, actual, report)
  end
end

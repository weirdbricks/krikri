describe "divergence corpus" do
  it "replays 1832-openssl-csr-crl-distribution-points-required" do
    expected, actual, report = divergence_transcripts(1832, "openssl-csr-crl-distribution-points-required")
    assert_equal(expected, actual, report)
  end
end

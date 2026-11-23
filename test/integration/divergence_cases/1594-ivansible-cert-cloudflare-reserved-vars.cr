describe "divergence corpus" do
  it "replays 1594-ivansible-cert-cloudflare-reserved-vars" do
    expected, actual, report = divergence_transcripts(1594, "ivansible-cert-cloudflare-reserved-vars")
    assert_equal(expected, actual, report)
  end
end

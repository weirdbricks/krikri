describe "divergence corpus" do
  it "replays 1826-lazyrichard-linux-join-ad-domain-untrusted-conditional" do
    expected, actual, report = divergence_transcripts(1826, "lazyrichard-linux-join-ad-domain-untrusted-conditional")
    assert_equal(expected, actual, report)
  end
end

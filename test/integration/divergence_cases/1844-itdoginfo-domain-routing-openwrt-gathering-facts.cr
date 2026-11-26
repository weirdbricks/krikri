describe "divergence corpus" do
  it "replays 1844-itdoginfo-domain-routing-openwrt-gathering-facts" do
    expected, actual, report = divergence_transcripts(1844, "itdoginfo-domain-routing-openwrt-gathering-facts")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1867-pyronear-openvpn-check-openvpn-variables" do
    expected, actual, report = divergence_transcripts(1867, "pyronear-openvpn-check-openvpn-variables")
    assert_equal(expected, actual, report)
  end
end

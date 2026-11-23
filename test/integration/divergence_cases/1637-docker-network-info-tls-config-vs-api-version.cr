describe "divergence corpus" do
  it "replays 1637-docker-network-info-tls-config-vs-api-version" do
    expected, actual, report = divergence_transcripts(1637, "docker-network-info-tls-config-vs-api-version")
    assert_equal(expected, actual, report)
  end
end

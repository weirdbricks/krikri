describe "divergence corpus" do
  it "replays 1647-artem-shestakov-elasticsearch-exporter-consul-check" do
    expected, actual, report = divergence_transcripts(1647, "artem-shestakov-elasticsearch-exporter-consul-check")
    assert_equal(expected, actual, report)
  end
end

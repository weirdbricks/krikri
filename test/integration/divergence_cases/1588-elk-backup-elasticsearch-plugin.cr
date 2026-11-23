describe "divergence corpus" do
  it "replays 1588-elk-backup-elasticsearch-plugin" do
    expected, actual, report = divergence_transcripts(1588, "elk-backup-elasticsearch-plugin")
    assert_equal(expected, actual, report)
  end
end

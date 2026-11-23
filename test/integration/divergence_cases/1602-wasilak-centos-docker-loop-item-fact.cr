describe "divergence corpus" do
  it "replays 1602-wasilak-centos-docker-loop-item-fact" do
    expected, actual, report = divergence_transcripts(1602, "wasilak-centos-docker-loop-item-fact")
    assert_equal(expected, actual, report)
  end
end

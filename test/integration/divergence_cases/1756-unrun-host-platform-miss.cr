describe "divergence corpus" do
  it "replays 1756-unrun-host-platform-miss" do
    expected, actual, report = divergence_transcripts(1756, "unrun-host-platform-miss")
    assert_equal(expected, actual, report)
  end
end

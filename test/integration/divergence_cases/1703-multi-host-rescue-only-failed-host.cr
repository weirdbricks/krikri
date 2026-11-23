describe "divergence corpus" do
  it "replays 1703-multi-host-rescue-only-failed-host" do
    expected, actual, report = divergence_transcripts(1703, "multi-host-rescue-only-failed-host")
    assert_equal(expected, actual, report)
  end
end

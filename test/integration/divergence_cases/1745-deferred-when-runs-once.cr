describe "divergence corpus" do
  it "replays 1745-deferred-when-runs-once" do
    expected, actual, report = divergence_transcripts(1745, "deferred-when-runs-once")
    assert_equal(expected, actual, report)
  end
end

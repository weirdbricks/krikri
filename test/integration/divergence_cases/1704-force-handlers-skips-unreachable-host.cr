describe "divergence corpus" do
  it "replays 1704-force-handlers-skips-unreachable-host" do
    expected, actual, report = divergence_transcripts(1704, "force-handlers-skips-unreachable-host")
    assert_equal(expected, actual, report)
  end
end

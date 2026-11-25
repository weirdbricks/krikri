describe "divergence corpus" do
  it "replays 1810-free-strategy-bypass-host-loop" do
    expected, actual, report = divergence_transcripts(1810, "free-strategy-bypass-host-loop")
    assert_equal(expected, actual, report)
  end
end

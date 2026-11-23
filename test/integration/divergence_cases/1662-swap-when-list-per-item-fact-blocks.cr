describe "divergence corpus" do
  it "replays 1662-swap-when-list-per-item-fact-blocks" do
    expected, actual, report = divergence_transcripts(1662, "swap-when-list-per-item-fact-blocks")
    assert_equal(expected, actual, report)
  end
end

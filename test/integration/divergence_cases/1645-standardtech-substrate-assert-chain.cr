describe "divergence corpus" do
  it "replays 1645-standardtech-substrate-assert-chain" do
    expected, actual, report = divergence_transcripts(1645, "standardtech-substrate-assert-chain")
    assert_equal(expected, actual, report)
  end
end

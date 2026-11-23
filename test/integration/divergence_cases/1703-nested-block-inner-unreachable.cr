describe "divergence corpus" do
  it "replays 1703-nested-block-inner-unreachable" do
    expected, actual, report = divergence_transcripts(1703, "nested-block-inner-unreachable")
    assert_equal(expected, actual, report)
  end
end

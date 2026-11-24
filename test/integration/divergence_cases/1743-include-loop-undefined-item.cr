describe "divergence corpus" do
  it "replays 1743-include-loop-undefined-item" do
    expected, actual, report = divergence_transcripts(1743, "include-loop-undefined-item")
    assert_equal(expected, actual, report)
  end
end

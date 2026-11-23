describe "divergence corpus" do
  it "replays 1733-block-skipped-loop-register" do
    expected, actual, report = divergence_transcripts(1733, "block-skipped-loop-register")
    assert_equal(expected, actual, report)
  end
end

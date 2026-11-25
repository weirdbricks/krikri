describe "divergence corpus" do
  it "replays 1805-copy-force-false-existing-dest-bogus-params" do
    expected, actual, report = divergence_transcripts(1805, "copy-force-false-existing-dest-bogus-params")
    assert_equal(expected, actual, report)
  end
end

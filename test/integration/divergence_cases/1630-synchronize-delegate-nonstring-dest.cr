describe "divergence corpus" do
  it "replays 1630-synchronize-delegate-nonstring-dest" do
    expected, actual, report = divergence_transcripts(1630, "synchronize-delegate-nonstring-dest")
    assert_equal(expected, actual, report)
  end
end

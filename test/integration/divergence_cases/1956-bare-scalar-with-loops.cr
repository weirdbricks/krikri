describe "divergence corpus" do
  it "replays 1956-bare-scalar-with-loops" do
    expected, actual, report = divergence_transcripts(1956, "bare-scalar-with-loops")
    assert_equal(expected, actual, report)
  end
end

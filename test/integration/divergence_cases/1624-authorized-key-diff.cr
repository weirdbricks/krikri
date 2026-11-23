describe "divergence corpus" do
  it "replays 1624-authorized-key-diff" do
    expected, actual, report = divergence_transcripts(1624, "authorized-key-diff")
    assert_equal(expected, actual, report)
  end
end

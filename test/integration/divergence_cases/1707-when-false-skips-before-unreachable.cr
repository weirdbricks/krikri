describe "divergence corpus" do
  it "replays 1707-when-false-skips-before-unreachable" do
    expected, actual, report = divergence_transcripts(1707, "when-false-skips-before-unreachable")
    assert_equal(expected, actual, report)
  end
end

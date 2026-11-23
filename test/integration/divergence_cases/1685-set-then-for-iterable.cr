describe "divergence corpus" do
  it "replays 1685-set-then-for-iterable" do
    expected, actual, report = divergence_transcripts(1685, "set-then-for-iterable")
    assert_equal(expected, actual, report)
  end
end

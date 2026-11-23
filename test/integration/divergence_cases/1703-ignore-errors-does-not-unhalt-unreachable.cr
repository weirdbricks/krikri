describe "divergence corpus" do
  it "replays 1703-ignore-errors-does-not-unhalt-unreachable" do
    expected, actual, report = divergence_transcripts(1703, "ignore-errors-does-not-unhalt-unreachable")
    assert_equal(expected, actual, report)
  end
end

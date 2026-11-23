describe "divergence corpus" do
  it "replays 1703-include-role-descends-before-unreachable" do
    expected, actual, report = divergence_transcripts(1703, "include-role-descends-before-unreachable")
    assert_equal(expected, actual, report)
  end
end

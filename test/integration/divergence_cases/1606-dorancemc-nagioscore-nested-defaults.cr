describe "divergence corpus" do
  it "replays 1606-dorancemc-nagioscore-nested-defaults" do
    expected, actual, report = divergence_transcripts(1606, "dorancemc-nagioscore-nested-defaults")
    assert_equal(expected, actual, report)
  end
end

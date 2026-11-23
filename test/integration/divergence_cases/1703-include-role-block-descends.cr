describe "divergence corpus" do
  it "replays 1703-include-role-block-descends" do
    expected, actual, report = divergence_transcripts(1703, "include-role-block-descends")
    assert_equal(expected, actual, report)
  end
end

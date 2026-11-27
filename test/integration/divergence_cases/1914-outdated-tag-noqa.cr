describe "divergence corpus" do
  it "replays 1914-outdated-tag-noqa" do
    expected, actual, report = divergence_transcripts(1914, "outdated-tag-noqa")
    assert_equal(expected, actual, report)
  end
end

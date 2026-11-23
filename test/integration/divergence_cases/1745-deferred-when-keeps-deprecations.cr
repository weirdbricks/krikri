describe "divergence corpus" do
  it "replays 1745-deferred-when-keeps-deprecations" do
    expected, actual, report = divergence_transcripts(1745, "deferred-when-keeps-deprecations")
    assert_equal(expected, actual, report)
  end
end

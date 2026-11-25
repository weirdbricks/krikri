describe "divergence corpus" do
  it "replays 1831-bodsch-harbor-update-package-cache-check" do
    expected, actual, report = divergence_transcripts(1831, "bodsch-harbor-update-package-cache-check")
    assert_equal(expected, actual, report)
  end
end

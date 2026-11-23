describe "divergence corpus" do
  it "replays 1640-cpanm-check-mode-skip" do
    expected, actual, report = divergence_transcripts(1640, "cpanm-check-mode-skip")
    assert_equal(expected, actual, report)
  end
end

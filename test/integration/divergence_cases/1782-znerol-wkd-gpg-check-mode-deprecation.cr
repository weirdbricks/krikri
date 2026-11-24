describe "divergence corpus" do
  it "replays 1782-znerol-wkd-gpg-check-mode-deprecation" do
    expected, actual, report = divergence_transcripts(1782, "znerol-wkd-gpg-check-mode-deprecation")
    assert_equal(expected, actual, report)
  end
end

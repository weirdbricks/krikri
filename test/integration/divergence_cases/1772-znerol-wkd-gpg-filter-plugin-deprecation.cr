describe "divergence corpus" do
  it "replays 1772-znerol-wkd-gpg-filter-plugin-deprecation" do
    expected, actual, report = divergence_transcripts(1772, "znerol-wkd-gpg-filter-plugin-deprecation")
    assert_equal(expected, actual, report)
  end
end

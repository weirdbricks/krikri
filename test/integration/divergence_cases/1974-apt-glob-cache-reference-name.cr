describe "divergence corpus" do
  it "replays 1974-apt-glob-cache-reference-name" do
    expected, actual, report = divergence_transcripts(1974, "apt-glob-cache-reference-name")
    assert_equal(expected, actual, report)
  end
end

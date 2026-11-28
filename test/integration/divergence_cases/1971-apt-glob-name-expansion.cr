describe "divergence corpus" do
  it "replays 1971-apt-glob-name-expansion" do
    expected, actual, report = divergence_transcripts(1971, "apt-glob-name-expansion")
    assert_equal(expected, actual, report)
  end
end

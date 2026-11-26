describe "divergence corpus" do
  it "replays 1864-apt-key-url-folded-newline" do
    expected, actual, report = divergence_transcripts(1864, "apt-key-url-folded-newline")
    assert_equal(expected, actual, report)
  end
end

describe "divergence corpus" do
  it "replays 1661-pacman-bool-type-name" do
    expected, actual, report = divergence_transcripts(1661, "pacman-bool-type-name")
    assert_equal(expected, actual, report)
  end
end

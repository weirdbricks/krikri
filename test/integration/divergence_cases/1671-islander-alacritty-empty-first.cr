describe "divergence corpus" do
  it "replays 1671-islander-alacritty-empty-first" do
    expected, actual, report = divergence_transcripts(1671, "islander-alacritty-empty-first")
    assert_equal(expected, actual, report)
  end
end

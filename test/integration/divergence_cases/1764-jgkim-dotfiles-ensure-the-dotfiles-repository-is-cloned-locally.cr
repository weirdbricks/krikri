describe "divergence corpus" do
  it "replays 1764-jgkim-dotfiles-ensure-the-dotfiles-repository-is-cloned-locally" do
    expected, actual, report = divergence_transcripts(1764, "jgkim-dotfiles-ensure-the-dotfiles-repository-is-cloned-locally")
    assert_equal(expected, actual, report)
  end
end
